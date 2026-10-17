defmodule Lilly.VM.Provisioning do
  @moduledoc "Locked progress journal and persistent readiness deadline for one placement."
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.{Journal, Provisioning}
  alias Lilly.VM.{Boot, Config, Spec}
  require Lilly.Events

  @type revision :: {pos_integer(), pos_integer()}
  @type result :: :ok | {:error, :provisioning_unconfirmed | :provisioning_busy}
  @phases ~w(pending materializing launching awaiting_trust awaiting_ssh unattested ready)

  # @cc [owner:ghuntley,label:recovery;concurrency] provisioning-lock-order
  # The driver MUST hold placement ownership before calling mutation functions.
  # Each mutation then acquires only the existing authoritative journal audit-lock.
  # Neither a network wait nor a pool lock may occur inside that journal lock.
  # The audit-lock wait MUST be bounded at two seconds in hostd's FIFO queue,
  # as for the outcome journal; only contention past it is provisioning_busy.
  @spec prepare(Config.t(), Spec.t(), revision()) :: result()
  def prepare(config, spec, revision) do
    mutate(config, spec, fn directory ->
      with :ok <- begin(directory, config, spec, revision),
           do: advance(directory, revision, "materializing", %{})
    end)
  end

  # @cc [owner:ghuntley,label:recovery] readiness-budget-by-agent-set
  # launching/4 MUST persist the readiness deadline from the caller's agent-set
  # budget (OverallsProtocol.GuestAgents.readiness_budget_ms/2) at the first launch
  # of an execution; re-entry through awaiting_trust reuses the persisted deadline
  # and falls back to the Linux profile default only for legacy callers that do
  # not supply the validated bundle agent set.
  @spec launching(Config.t(), Spec.t(), Boot.t(), pos_integer() | nil) :: result()
  def launching(config, spec, boot, budget \\ nil) do
    mutate(config, spec, fn directory ->
      launch(directory, spec, boot, budget)
    end)
  end

  # @cc [owner:ghuntley,label:recovery] awaiting-trust-preserves-agent-budget
  # awaiting_trust/4 MUST pass the validated placement agent-set budget through
  # when a first launch has not persisted a deadline. Re-entry MUST retain the
  # existing deadline, even when a later caller supplies a different budget.
  # A nil budget is retained for legacy direct callers and uses the Linux
  # profile default only when no durable deadline exists.
  #
  # Called only after physical confined authority has been confirmed. A running
  # boot whose logical generation advanced acquires that generation's journal
  # from the same proof, superseding the previous generation's record.
  @spec awaiting_trust(Config.t(), Spec.t(), Boot.t(), pos_integer() | nil) :: result()
  def awaiting_trust(config, spec, boot, budget \\ nil) do
    mutate(config, spec, fn directory ->
      expected = revision(boot)

      with :ok <- begin(directory, config, spec, expected),
           :ok <- advance(directory, expected, "materializing", %{}),
           :ok <- launch(directory, spec, boot, budget) do
        advance(directory, expected, "awaiting_trust", %{"boot_challenge" => boot.boot_challenge})
      end
    end)
  end

  @spec awaiting_ssh(Config.t(), Spec.t(), Boot.t()) :: result()
  def awaiting_ssh(config, spec, boot) do
    mutate(config, spec, fn directory ->
      advance(directory, revision(boot), "awaiting_ssh", %{
        "boot_challenge" => boot.boot_challenge
      })
    end)
  end

  # @cc [owner:ghuntley,label:recovery;security] provisioning-receipt-current-boot
  # ready/4 MUST be called only after Driver rechecks current confined execution
  # and boot identity following the guest exchange. A late proof MUST NOT publish
  # success. Readiness state MUST persist before the running observation;
  # diagnostic delivery MUST NOT gate that observation.
  @spec ready(Config.t(), Spec.t(), Boot.t(), OverallsProtocol.uuid()) :: result()
  def ready(config, spec, boot, boot_id) do
    mutate(config, spec, fn directory ->
      with {:ok, record} when not is_nil(record) <- load(directory),
           true <- record.payload["deadline"] > System.system_time(:millisecond),
           :ok <-
             advance(directory, revision(boot), "ready", %{
               "boot_challenge" => boot.boot_challenge,
               "boot_id" => boot_id
             }) do
        if record.state != :ready do
          Lilly.Events.emit("vm.provisioning_ready",
            placement_id: spec.id,
            execution_epoch: boot.execution_epoch,
            generation: boot.generation,
            duration_ms: max(System.system_time(:millisecond) - record.payload["started_at"], 0)
          )
        end

        :ok
      else
        _ -> {:error, :provisioning_unconfirmed}
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery;security] provisioning-unattested-terminal
  # unattested/3 MUST advance an awaiting_trust record to `unattested` for the
  # exact boot without a guest exchange, deadline check or boot UUID. The
  # lifecycle refuses `ready` after `unattested`, so an agentless guest can never
  # acquire a readiness receipt. The commit is emitted once per record.
  @spec unattested(Config.t(), Spec.t(), Boot.t()) :: result()
  def unattested(config, spec, boot) do
    mutate(config, spec, fn directory ->
      with {:ok, record} when not is_nil(record) <- load(directory),
           :ok <-
             advance(directory, revision(boot), "unattested", %{
               "boot_challenge" => boot.boot_challenge
             }) do
        if record.state != :unattested do
          Lilly.Events.emit("vm.provisioning_unattested",
            placement_id: spec.id,
            execution_epoch: boot.execution_epoch,
            generation: boot.generation
          )
        end

        :ok
      else
        _ -> {:error, :provisioning_unconfirmed}
      end
    end)
  end

  @spec status(Config.t(), Spec.t(), Boot.t()) ::
          {:ready, OverallsProtocol.uuid()}
          | :unattested
          | {:wait, non_neg_integer()}
          | {:error, :provisioning_unconfirmed}
  def status(config, spec, boot) do
    with {:ok, record} when not is_nil(record) <- load(directory(config, spec)),
         true <- record.payload["host_id"] == config.network.host_id,
         true <- record.payload["placement_id"] == spec.id,
         true <- current?(record.payload, revision(boot)),
         true <- record.payload["boot_challenge"] == boot.boot_challenge do
      case record.state do
        :ready ->
          {:ready, record.payload["boot_id"]}

        :unattested ->
          :unattested

        state when state in [:awaiting_trust, :awaiting_ssh] ->
          {:wait, max(record.payload["deadline"] - System.system_time(:millisecond), 0)}

        _ ->
          {:error, :provisioning_unconfirmed}
      end
    else
      _ -> {:error, :provisioning_unconfirmed}
    end
  end

  @spec fail(Config.t(), Spec.t(), revision()) :: result()
  def fail(config, spec, expected) do
    mutate(config, spec, fn directory ->
      case load(directory) do
        {:ok, nil} ->
          :ok

        {:ok, record} ->
          cond do
            not bound?(record, config, spec) -> {:error, :provisioning_unconfirmed}
            not current?(record.payload, expected) -> {:error, :provisioning_unconfirmed}
            record.state in [:ready, :failed, :superseded] -> :ok
            true -> write(directory, Map.put(record.payload, "state", "failed"))
          end

        _ ->
          {:error, :provisioning_unconfirmed}
      end
    end)
  end

  defp launch(directory, spec, boot, budget) do
    with {:ok, record} when not is_nil(record) <- load(directory) do
      now = record.payload["launched_at"] || System.system_time(:millisecond)

      budget =
        budget || OverallsProtocol.GuestAgents.readiness_budget_ms(:linux, spec.network.profile)

      advance(directory, revision(boot), "launching", %{
        "boot_challenge" => boot.boot_challenge,
        "launched_at" => now,
        "deadline" => record.payload["deadline"] || now + budget
      })
    end
  end

  @doc "Retire progress only after the caller fences and physically stops the placement."
  @spec cancel(Config.t(), Spec.t(), revision()) :: result()
  def cancel(config, spec, fence) do
    mutate(config, spec, fn directory ->
      with {:ok, record} <- load(directory),
           true <- is_nil(record) or bound?(record, config, spec),
           true <-
             is_nil(record) or
               {record.payload["execution_epoch"], record.payload["generation"]} <= fence,
           do: supersede(directory, record)
    end)
  end

  defp bound?(record, config, spec),
    do:
      record.payload["host_id"] == config.network.host_id and
        record.payload["placement_id"] == spec.id

  defp begin(directory, config, spec, {epoch, generation} = expected) do
    with {:ok, previous} <- load(directory),
         true <-
           is_nil(previous) or
             (previous.payload["host_id"] == config.network.host_id and
                previous.payload["placement_id"] == spec.id) do
      cond do
        previous && current?(previous.payload, expected) ->
          if previous.state in [:failed, :superseded],
            do: {:error, :provisioning_unconfirmed},
            else: :ok

        previous &&
            {previous.payload["execution_epoch"], previous.payload["generation"]} >= expected ->
          {:error, :provisioning_unconfirmed}

        true ->
          now = System.system_time(:millisecond)

          with :ok <- supersede(directory, previous) do
            write(directory, %{
              "state" => "pending",
              "host_id" => config.network.host_id,
              "placement_id" => spec.id,
              "execution_epoch" => epoch,
              "generation" => generation,
              "started_at" => now,
              "launched_at" => nil,
              "deadline" => nil,
              "boot_challenge" => nil,
              "boot_id" => nil
            })
          end
      end
    end
  end

  defp supersede(_, nil), do: :ok

  defp supersede(directory, previous),
    do: write(directory, Map.put(previous.payload, "state", "superseded"))

  defp advance(directory, expected, target, attrs) do
    with {:ok, record} when not is_nil(record) <- load(directory),
         true <- current?(record.payload, expected),
         true <- record.payload["state"] in @phases,
         # An agentless record never takes the agent readiness phases, not even
         # as an idempotent no-op; re-entering awaiting_trust (trust and the
         # unattested commit re-run on restart and adoption) stays a no-op.
         true <- record.payload["state"] != "unattested" or target not in ~w(awaiting_ssh ready),
         true <-
           Enum.all?(attrs, fn {key, value} ->
             is_nil(record.payload[key]) or record.payload[key] == value
           end) do
      if Enum.find_index(@phases, &(&1 == record.payload["state"])) >=
           Enum.find_index(@phases, &(&1 == target)),
         do: :ok,
         else: write(directory, record.payload |> Map.merge(attrs) |> Map.put("state", target))
    else
      _ -> {:error, :provisioning_unconfirmed}
    end
  end

  defp current?(payload, {epoch, generation}),
    do: payload["execution_epoch"] == epoch and payload["generation"] == generation

  defp revision(boot), do: {boot.execution_epoch, boot.generation}
  defp directory(config, spec), do: Path.join(config.state_dir, spec.id)
  defp load(directory), do: Journal.load(Provisioning, directory, "provisioning.json")

  defp write(directory, payload),
    do: Journal.write(Provisioning, directory, "provisioning.json", payload)

  defp mutate(config, spec, fun) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- Lock.held?(port),
         directory = directory(config, spec),
         {:ok, lock} <- Lock.acquire(Path.join(directory, "audit-lock"), 2000) do
      try do
        case fun.(directory) do
          :ok -> :ok
          _ -> {:error, :provisioning_unconfirmed}
        end
      after
        Lock.release(lock)
      end
    else
      {:error, :host_already_owned} -> {:error, :provisioning_busy}
      _ -> {:error, :provisioning_unconfirmed}
    end
  end
end
