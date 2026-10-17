defmodule OverallsAntithesis.Terminal do
  @moduledoc """
  Closed terminal operations for the isolated fixture's real Marshall authority.

  The private response is a control receipt, not evidence of a guest PTY. The
  workload observes the durable registry and current guest separately.
  """

  alias OverallsAntithesis.Fixture
  alias Marshall.Accounts.User
  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    HostLiveness,
    Ledger,
    PhysicalOutcome,
    VirtualMachine,
    WorkloadPlacement
  }

  alias Marshall.Terminal.{Authority, Opening, Session}
  require Ash.Query

  @operations ~w(terminal.create terminal.get terminal.ticket terminal.kill)
  @roles ~w(admin_a admin_b target)
  @retryable ~w(terminal_open_pending terminal_unavailable stream_unavailable)

  @type operation ::
          :create | :get | :ticket | :kill
  @type request :: %{
          required(String.t()) => String.t() | integer()
        }
  @type value :: %{required(String.t()) => String.t() | integer() | nil}
  @type result :: {:ok, value()} | {:error, atom()}

  # @cc [owner:ghuntley,label:security;verification] terminal-fixture-closed-commands
  # Request data MUST select only a fixed fixture actor and one of four named
  # terminal operations. It MUST NOT select a guest username, command, code
  # path or payload. A successful control receipt is not physical PTY proof.
  @spec main([String.t()]) :: :ok | no_return()
  def main([name, manifest_path, request_path, result_path]) when name in @operations do
    if System.get_env("MARSHALL_INSTANCE_ID") != "enrollment-operator" or
         Application.get_env(:marshall, :operator_mode) != true or
         not File.regular?("/run/overalls-oracle/fixture.json") do
      System.halt(1)
    end

    manifest = Fixture.read_manifest!(manifest_path)
    request = request_path |> File.read!() |> JSON.decode!()
    {:ok, operation} = parse_request(name, request)
    actor = Fixture.actor!(manifest, request["actor"])
    result = run(operation, actor, request)
    receipt = receipt(name, request["request_id"], result)
    Fixture.write_private!(result_path, receipt)
  rescue
    _ -> System.halt(1)
  catch
    _, _ -> System.halt(1)
  end

  def main(_), do: System.halt(1)

  @doc false
  @spec parse_request(String.t(), term()) :: {:ok, operation()} | {:error, :invalid_request}
  def parse_request(
        name,
        %{"version" => 1, "operation" => name, "request_id" => id, "actor" => role} = request
      )
      when name in @operations and role in @roles do
    keys = request |> Map.keys() |> Enum.sort()

    expected =
      case name do
        "terminal.create" -> ~w(actor create_request_id operation request_id version vm_id)
        "terminal.get" -> ~w(actor create_request_id operation request_id version)
        _ -> ~w(actor operation request_id session_id version)
      end

    identifier =
      case name do
        "terminal.create" -> request["create_request_id"]
        "terminal.get" -> request["create_request_id"]
        _ -> request["session_id"]
      end

    if keys == expected and OverallsProtocol.uuid?(id) and
         OverallsProtocol.uuid?(identifier) and
         (name != "terminal.create" or OverallsProtocol.uuid?(request["vm_id"])) do
      {:ok, operation(name)}
    else
      {:error, :invalid_request}
    end
  end

  def parse_request(_, _), do: {:error, :invalid_request}

  @spec operation(String.t()) :: operation()
  defp operation("terminal.create"), do: :create
  defp operation("terminal.get"), do: :get
  defp operation("terminal.ticket"), do: :ticket
  defp operation("terminal.kill"), do: :kill

  @spec run(operation(), User.t(), request()) :: result()
  defp run(:create, actor, request) do
    id = request["create_request_id"]

    with {:ok, _view} <- Compute.get_vm(%{vm_id: request["vm_id"]}, actor: actor),
         [vm] <- Ledger.read!(VirtualMachine, id: request["vm_id"]),
         :ok <- current_integrated_boot(vm),
         result <- Authority.open_personal_session(vm, actor, id) do
      case result do
        {:ok, session} ->
          {:ok,
           %{
             "status" => "ready",
             "create_request_id" => id,
             "session_id" => session.id,
             "guest_session_id" => session.guest_session_id
           }}

        {:error, reason} when is_atom(reason) ->
          if Atom.to_string(reason) in @retryable do
            {:ok, %{"status" => "pending", "create_request_id" => id}}
          else
            {:ok, %{"status" => "failed", "create_request_id" => id}}
          end
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :terminal_unavailable}
    end
  end

  defp run(:get, actor, request) do
    id = request["create_request_id"]

    with {:ok, %Opening{} = opening} <- Ash.get(Opening, id, authorize?: false),
         true <- opening.actor_id == actor.id,
         {:ok, _vm} <- Compute.get_vm(%{vm_id: opening.vm_id}, actor: actor) do
      value = %{
        "status" => Atom.to_string(opening.status),
        "create_request_id" => id,
        "placement_id" => opening.placement_id,
        "execution_epoch" => opening.execution_epoch
      }

      if opening.status == :ready do
        case Ash.get(Session, opening.session_id, authorize?: false) do
          {:ok, %Session{} = session} when session.owner_id == actor.id ->
            {:ok,
             value
             |> Map.put("session_id", session.id)
             |> Map.put("guest_session_id", session.guest_session_id)}

          _ ->
            {:error, :terminal_unavailable}
        end
      else
        {:ok, value}
      end
    else
      false -> {:error, :forbidden}
      {:error, _} -> {:error, :terminal_unavailable}
      _ -> {:error, :terminal_unavailable}
    end
  end

  defp run(:ticket, actor, request) do
    with {:ok, session} <- Authority.session_for(request["session_id"], actor),
         :ok <- current_integrated_session(session, actor),
         {:ok, ticket} <- Authority.ticket(session, actor) do
      {:ok, %{"session_id" => session.id, "ticket" => ticket}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :terminal_unavailable}
    end
  end

  defp run(:kill, actor, request) do
    with {:ok, session} <- Authority.session_for(request["session_id"], actor),
         :ok <- current_integrated_session(session, actor) do
      case Authority.close_session(session, actor) do
        :ok ->
          {:ok, %{"status" => "closed", "session_id" => session.id}}

        {:error, :terminal_close_pending} ->
          {:ok, %{"status" => "pending", "session_id" => session.id}}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :terminal_unavailable}
    end
  end

  @spec current_integrated_session(Session.t(), User.t()) :: :ok | {:error, atom()}
  defp current_integrated_session(session, actor) do
    with {:ok, _view} <- Compute.get_vm(%{vm_id: session.vm_id}, actor: actor),
         [vm] <- Ledger.read!(VirtualMachine, id: session.vm_id),
         true <-
           vm.current_placement_id == session.placement_id and
             vm.execution_epoch == session.execution_epoch,
         do: current_integrated_boot(vm),
         else: (_ -> {:error, :terminal_unavailable})
  end

  # @cc [owner:ghuntley,label:verification;security] terminal-current-physical-gate
  # Side-effecting terminal calls MUST require a fresh report from the measured
  # integrated Lilly host and a committed guest-ready outcome for the VM's
  # current placement, epoch and generation. Missing evidence is unavailable.
  # The workload's independent guest witness remains necessary for PTY claims.
  @spec current_integrated_boot(Compute.VirtualMachine.t()) :: :ok | {:error, atom()}
  defp current_integrated_boot(vm) do
    with true <- vm.desired_state == :running and vm.observed_state == :running,
         [placement] <- Ledger.read!(WorkloadPlacement, id: vm.current_placement_id),
         [host] <- Ledger.read!(Host, id: placement.host_id),
         true <-
           host.name == "lilly-host" and host.enabled and
             host.inventory["terminal_protocol"] == 2 and
             host.inventory["execution_ready"] == true,
         true <-
           HostLiveness.capacity_fresh?(host.reported_at, Ledger.now()) and
             is_binary(host.connection_session_id),
         true <- ready_outcome?(vm, host.id) do
      :ok
    else
      _ -> {:error, :terminal_unavailable}
    end
  rescue
    _ -> {:error, :terminal_unavailable}
  end

  @spec ready_outcome?(Compute.VirtualMachine.t(), String.t()) :: boolean()
  defp ready_outcome?(vm, host_id) do
    PhysicalOutcome
    |> Ash.Query.filter(
      vm_id == ^vm.id and host_id == ^host_id and
        placement_id == ^vm.current_placement_id and execution_epoch == ^vm.execution_epoch and
        generation == ^vm.generation
    )
    |> Ash.read!(authorize?: false)
    |> Enum.any?(fn row ->
      case OverallsProtocol.Execution.outcome(row.observation) do
        {:ok, outcome} ->
          outcome.id == row.id and outcome.vm_id == vm.id and
            outcome.placement_id == vm.current_placement_id and
            outcome.execution_epoch == vm.execution_epoch and
            outcome.generation == vm.generation and outcome.state == :running and
            Map.get(outcome, :guest_ready) == true

        _ ->
          false
      end
    end)
  end

  @spec receipt(String.t(), String.t(), result()) :: map()
  defp receipt(name, id, {:ok, value}),
    do: %{
      "version" => 1,
      "operation" => name,
      "request_id" => id,
      "status" => "ok",
      "value" => value
    }

  defp receipt(name, id, {:error, reason}) when is_atom(reason),
    do: %{
      "version" => 1,
      "operation" => name,
      "request_id" => id,
      "status" => "error",
      "reason" => closed_reason(reason)
    }

  @spec closed_reason(atom()) :: String.t()
  defp closed_reason(reason)
       when reason in [
              :forbidden,
              :unknown_session,
              :terminal_unavailable,
              :terminal_close_pending,
              :guest_account_unavailable,
              :invalid_terminal_request,
              :opening_expired,
              :too_many_terminal_sessions,
              :rejected,
              :limit
            ],
       do: Atom.to_string(reason)

  defp closed_reason(_), do: "terminal_unavailable"
end
