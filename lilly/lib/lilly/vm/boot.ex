defmodule Lilly.VM.Boot do
  @moduledoc "Host-local boot challenge persisted before a physical launch attempt."
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  alias Lilly.VM.Intent
  @maximum 9_223_372_036_854_775_807
  @type t :: %{
          optional(:guest_identity) => OverallsProtocol.Readiness.expectation(),
          optional(:guest_boot_id) => OverallsProtocol.uuid(),
          optional(:checkpoint_id) => OverallsProtocol.uuid(),
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          boot_challenge: String.t()
        }

  # @cc [owner:ghuntley,label:recovery] boot-challenge-before-launch
  # prepare/2 requires the caller's per-placement host lock, a matching running intent,
  # and proof that this authority has not attempted launch. It MUST persist a random
  # challenge before returning, reuse it for the same unattempted boot, and rotate it
  # for a newer epoch/generation. Corrupt state, rebinding and regression MUST fail closed.
  @spec prepare(Path.t(), Intent.t()) :: {:ok, t()} | {:error, atom()}
  def prepare(directory, intent) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, ^intent} <- Intent.read(directory),
         true <- intent.state == :running,
         {:ok, previous} <- read(directory),
         {:ok, boot} <- next(previous, intent),
         :ok <- PrivateFiles.write(directory, "boot.json", JSON.encode!(encode(boot))),
         {:ok, _} <- Command.run(:sync, ["--", Path.dirname(directory)]) do
      {:ok, boot}
    else
      _ -> {:error, :boot_identity_unconfirmed}
    end
  end

  @spec read(Path.t()) :: {:ok, t() | nil} | {:error, :boot_identity_unconfirmed}
  def read(directory) do
    path = Path.join(directory, "boot.json")

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, _} ->
        with {:ok, body} <- PrivateFiles.read_secret(path),
             {:ok, %{"version" => 1, "generation" => generation} = value} <- JSON.decode(body),
             true <-
               Map.keys(value) --
                 ~w(version generation placement_id execution_epoch boot_challenge guest_identity guest_boot_id checkpoint_id) ==
                 [],
             true <- is_integer(generation) and generation in 1..@maximum,
             {:ok, observed} <-
               OverallsProtocol.Readiness.response(%{
                 "version" => 1,
                 "state" => "ready",
                 "placement_id" => value["placement_id"],
                 "execution_epoch" => value["execution_epoch"],
                 "boot_challenge" => value["boot_challenge"],
                 "boot_id" => value["placement_id"]
               }) do
          boot = observed |> Map.delete(:boot_id) |> Map.put(:generation, generation)
          with {:ok, boot} <- continuation(boot, value), do: {:ok, boot}
        else
          _ -> {:error, :boot_identity_unconfirmed}
        end

      _ ->
        {:error, :boot_identity_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] continuing-boot-generation-adoption
  # The caller MUST own the placement lock and have proved the existing confined
  # VMM before adoption. Only the exact current running intent and the same
  # placement/execution epoch MAY advance the journal generation. Adoption MUST
  # preserve the boot challenge and refuse missing, corrupt or regressing state.
  # It does not establish guest readiness or authorize a different physical boot.
  @spec adopt_generation(Path.t(), Intent.t()) ::
          {:ok, t()} | {:error, :boot_identity_unconfirmed}
  def adopt_generation(directory, intent) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, ^intent} <- Intent.read(directory),
         true <- intent.state == :running,
         {:ok, %{} = previous} <- read(directory),
         true <- previous.placement_id == intent.placement_id,
         true <- previous.execution_epoch == intent.execution_epoch,
         true <- previous.generation <= intent.generation,
         adopted = %{previous | generation: intent.generation},
         :ok <- persist_adoption(directory, previous, adopted),
         {:ok, _} <- Command.run(:sync, ["--", Path.dirname(directory)]) do
      {:ok, adopted}
    else
      _ -> {:error, :boot_identity_unconfirmed}
    end
  end

  @spec persist_adoption(Path.t(), t(), t()) :: :ok | {:error, atom()}
  defp persist_adoption(_directory, same, same), do: :ok

  defp persist_adoption(directory, _previous, adopted),
    do: PrivateFiles.write(directory, "boot.json", JSON.encode!(encode(adopted)))

  # @cc [owner:ghuntley,label:recovery] current-boot-requires-current-running-intent
  # current/3 MUST reject missing boot state and any mismatch between the requested
  # placement/epoch/generation, persisted boot and running launch intent. Callers
  # using the result as authority MUST hold the per-placement lock and recheck it
  # after asynchronous observation; reading files alone does not fence a transition.
  @spec current(Path.t(), OverallsProtocol.uuid(), {pos_integer(), pos_integer() | nil}) ::
          {:ok, t()} | {:error, :boot_identity_unconfirmed}
  def current(directory, placement, {epoch, generation}) do
    with {:ok,
          %{
            placement_id: ^placement,
            execution_epoch: ^epoch,
            generation: ^generation,
            state: :running
          }} <- Intent.read(directory),
         {:ok,
          %{placement_id: ^placement, execution_epoch: ^epoch, generation: ^generation} = boot} <-
           read(directory) do
      {:ok, boot}
    else
      _ -> {:error, :boot_identity_unconfirmed}
    end
  end

  @spec expectation(t()) :: OverallsProtocol.Readiness.expectation()
  def expectation(boot),
    do:
      Map.get(
        boot,
        :guest_identity,
        Map.take(boot, [:placement_id, :execution_epoch, :boot_challenge])
      )

  # @cc [owner:ghuntley,label:security;recovery] continued-boot-separates-current-authority
  # continue/4 requires a verified single-use checkpoint and the placement lock.
  # The new host authority MUST match intent.bin while guest wire identity and
  # captured boot UUID remain unchanged. Portable metadata alone grants no launch.
  @spec continue(Path.t(), Intent.t(), map(), OverallsProtocol.uuid()) ::
          {:ok, t()} | {:error, :boot_identity_unconfirmed}
  def continue(directory, intent, manifest, checkpoint_id) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, ^intent} <- Intent.read(directory),
         true <- intent.state == :running,
         {:ok, guest} <- guest_identity(manifest["guest_identity"]),
         true <- OverallsProtocol.uuid?(checkpoint_id),
         true <-
           is_nil(manifest["guest_boot_id"]) or OverallsProtocol.uuid?(manifest["guest_boot_id"]),
         boot =
           intent
           |> Map.take([:placement_id, :execution_epoch, :generation])
           |> Map.merge(%{
             boot_challenge: guest.boot_challenge,
             guest_identity: guest,
             checkpoint_id: checkpoint_id
           }),
         boot =
           if(manifest["guest_boot_id"],
             do: Map.put(boot, :guest_boot_id, manifest["guest_boot_id"]),
             else: boot
           ),
         :ok <- PrivateFiles.write(directory, "boot.json", JSON.encode!(encode(boot))),
         do: {:ok, boot},
         else: (_ -> {:error, :boot_identity_unconfirmed})
  end

  @spec record_boot_id(Path.t(), t(), OverallsProtocol.uuid()) :: :ok | {:error, atom()}
  def record_boot_id(directory, boot, boot_id) do
    with true <- OverallsProtocol.uuid?(boot_id),
         {:ok, ^boot} <- read(directory),
         true <- Map.get(boot, :guest_boot_id, boot_id) == boot_id,
         do:
           PrivateFiles.write(
             directory,
             "boot.json",
             JSON.encode!(encode(Map.put(boot, :guest_boot_id, boot_id)))
           ),
         else: (_ -> {:error, :boot_identity_unconfirmed})
  end

  defp continuation(boot, wire) do
    case Map.take(wire, ~w(guest_identity checkpoint_id)) do
      empty when map_size(empty) == 0 ->
        if is_nil(wire["guest_boot_id"]) or OverallsProtocol.uuid?(wire["guest_boot_id"]),
          do:
            {:ok,
             if(wire["guest_boot_id"],
               do: Map.put(boot, :guest_boot_id, wire["guest_boot_id"]),
               else: boot
             )},
          else: {:error, :boot_identity_unconfirmed}

      %{"guest_identity" => guest, "checkpoint_id" => checkpoint} ->
        with {:ok, guest} <- guest_identity(guest),
             true <- OverallsProtocol.uuid?(checkpoint),
             true <-
               is_nil(wire["guest_boot_id"]) or OverallsProtocol.uuid?(wire["guest_boot_id"]) do
          boot = Map.merge(boot, %{guest_identity: guest, checkpoint_id: checkpoint})

          {:ok,
           if(wire["guest_boot_id"],
             do: Map.put(boot, :guest_boot_id, wire["guest_boot_id"]),
             else: boot
           )}
        else
          _ -> {:error, :boot_identity_unconfirmed}
        end

      _ ->
        {:error, :boot_identity_unconfirmed}
    end
  end

  defp guest_identity(value) when is_map(value) and map_size(value) == 3 do
    with {:ok, response} <-
           OverallsProtocol.Readiness.response(
             Map.merge(value, %{
               "version" => 1,
               "state" => "ready",
               "boot_id" => value["placement_id"]
             })
           ),
         do: {:ok, Map.delete(response, :boot_id)}
  end

  defp guest_identity(_), do: {:error, :boot_identity_unconfirmed}

  defp next(nil, intent), do: {:ok, fresh(intent)}

  defp next(previous, intent) do
    cond do
      previous.placement_id != intent.placement_id ->
        {:error, :placement_changed}

      {previous.execution_epoch, previous.generation} ==
          {intent.execution_epoch, intent.generation} ->
        {:ok, previous}

      {previous.execution_epoch, previous.generation} <
          {intent.execution_epoch, intent.generation} ->
        {:ok, fresh(intent)}

      true ->
        {:error, :stale_boot}
    end
  end

  defp fresh(intent) do
    intent
    |> Map.take([:placement_id, :execution_epoch, :generation])
    |> Map.put(:boot_challenge, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))
  end

  defp encode(boot),
    do:
      boot
      |> Map.new(fn {key, value} ->
        {Atom.to_string(key),
         if(is_map(value),
           do: Map.new(value, fn {k, v} -> {Atom.to_string(k), v} end),
           else: value
         )}
      end)
      |> Map.put("version", 1)
end
