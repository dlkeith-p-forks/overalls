defmodule Lilly.VM.Boot do
  @moduledoc "Host-local boot challenge persisted before a physical launch attempt."
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  alias Lilly.VM.Intent
  @maximum 9_223_372_036_854_775_807
  @type t :: %{
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
             true <- map_size(value) == 5 and is_integer(generation) and generation in 1..@maximum,
             {:ok, observed} <-
               OverallsProtocol.Readiness.response(%{
                 "version" => 1,
                 "state" => "ready",
                 "placement_id" => value["placement_id"],
                 "execution_epoch" => value["execution_epoch"],
                 "boot_challenge" => value["boot_challenge"],
                 "boot_id" => value["placement_id"]
               }) do
          {:ok, observed |> Map.delete(:boot_id) |> Map.put(:generation, generation)}
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
  def expectation(boot), do: Map.take(boot, [:placement_id, :execution_epoch, :boot_challenge])

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
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("version", 1)
end
