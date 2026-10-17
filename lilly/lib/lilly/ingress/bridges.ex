defmodule Lilly.Ingress.Bridges do
  @moduledoc """
  Detached ingress bridges (ADR-0187): their records, keepers and
  re-adoption.

  hostd bridges Audi's connection straight to the guest in a
  `lilly-ingress-<key>.scope` that outlives hostd and Lilly. Lilly keeps the
  authority to end it: each live bridge has one keeper process that owns an
  ingress guardian for the bridge's binding and asks hostd to end the bridge
  when that guardian dies. The binding is recorded under the key before the
  bridge starts, so a restarted Lilly can find every bridge (hostd lists the
  scopes) and give it a keeper again, or end it.
  """
  alias Lilly.Host.PrivateFiles
  alias OverallsProtocol.IngressConnect
  require Lilly.Events

  @typedoc "A bridge key: 16 random bytes; its scope is lilly-ingress-<hex>.scope."
  @type key :: <<_::128>>
  @typedoc "Lists and ends bridges: `{module, context}` with live/1 and end_bridge/2."
  @type host :: {module(), term()}
  @typedoc "A recorded binding, or :unknown when no readable record exists."
  @type binding :: map() | :unknown

  # How long a restarted Lilly lets a recorded bridge wait for its execution
  # to become current again before ending it.
  @adoption_grace 30_000
  # How long a freshly started bridge's keeper may take to re-establish the
  # guardian the starting worker held.
  @handoff_grace 2_000
  @retry 250
  @end_attempts 3

  @doc "The production host: lilly-hostd."
  @spec live(term()) :: {:ok, [key()]} | {:error, term()}
  def live(_context), do: Lilly.Host.Hostd.ingress_bridges()

  @spec end_bridge(term(), key()) :: :ok | {:error, term()}
  def end_bridge(_context, key), do: Lilly.Host.Hostd.end_ingress_bridge(key)

  @doc "The private record directory beside the connector socket."
  @spec directory(Path.t()) :: Path.t()
  def directory(socket_path), do: socket_path <> ".bridges"

  @spec new_key() :: key()
  def new_key, do: :crypto.strong_rand_bytes(16)

  @spec name(key()) :: String.t()
  def name(<<_::128>> = key), do: Base.encode16(key, case: :lower)

  @doc "The time a bridge has to be guarded again, by why it needs a keeper."
  @spec grace(:handoff | :adopt) :: pos_integer()
  def grace(:handoff), do: @handoff_grace
  def grace(:adopt), do: @adoption_grace

  # @cc [owner:ghuntley,label:recovery;security] ingress-bridge-recorded-before-start
  # record/3 MUST durably write the bridge's complete connector binding under
  # its key in Lilly's private 0700 directory before the bridge is requested,
  # so every bridge a restarted Lilly finds has a binding to fence it by. A
  # record never holds a credential: only the IngressConnect binding fields.
  @spec record(Path.t(), key(), map()) :: :ok | {:error, atom()}
  def record(directory, key, binding) do
    with {:ok, bytes} <- IngressConnect.encode(binding),
         do: PrivateFiles.write(directory, name(key), bytes)
  end

  @spec forget(Path.t(), key()) :: :ok
  def forget(directory, key) do
    _ = File.rm(Path.join(directory, name(key)))
    :ok
  end

  @doc "Every record by key; an unreadable or invalid record is :unknown."
  @spec records(Path.t()) :: %{key() => binding()}
  def records(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        for name <- names,
            {:ok, key} <- [Base.decode16(name, case: :lower)],
            byte_size(key) == 16,
            into: %{} do
          {key, read(Path.join(directory, name))}
        end

      _ ->
        %{}
    end
  end

  defp read(path) do
    with {:ok, bytes} <- PrivateFiles.read_secret(path),
         {:ok, binding} <- IngressConnect.decode(bytes),
         true <- Lilly.Network.Ingress.detachable?(binding) do
      binding
    else
      _ -> :unknown
    end
  end

  @doc "Start a keeper linked to the caller."
  @spec start_keeper({module(), term()}, host(), Path.t(), key(), binding(), :handoff | :adopt) ::
          pid()
  def start_keeper(backend, host, directory, key, binding, mode) do
    spawn_link(fn -> keep(backend, host, directory, key, binding, grace(mode)) end)
  end

  # @cc [owner:ghuntley,label:security;recovery] ingress-bridge-keeper-fence
  # A keeper MUST obtain a guardian for its bridge's recorded binding
  # (retrying only until its grace ends: 2 s after a handoff, 30 s after a
  # restart) and then end the bridge through hostd as soon as that guardian
  # dies. A bridge whose binding is :unknown, or that is not guarded within
  # its grace, MUST be ended at once. `:ended` (the bridge is gone) stops the
  # keeper and its guardian. The record is removed only once hostd confirmed
  # the bridge ended or it was gone; the keeper's own death (Lilly stopping)
  # leaves the bridge and its record for the next keeper.
  defp keep(backend, host, directory, key, binding, grace) do
    deadline = System.monotonic_time(:millisecond) + grace

    case guard(backend, binding, deadline) do
      {:ok, guardian} ->
        ref = Process.monitor(guardian)

        receive do
          {:DOWN, ^ref, :process, _, _} ->
            finish(host, directory, key, :fenced)

          :ended ->
            Process.exit(guardian, :kill)
            forget(directory, key)
        end

      :ended ->
        forget(directory, key)

      :error ->
        finish(host, directory, key, if(binding == :unknown, do: :unknown, else: :unadopted))
    end
  end

  defp guard(_backend, :unknown, _deadline), do: :error

  defp guard({module, context} = backend, binding, deadline) do
    receive do
      :ended -> :ended
    after
      0 ->
        case safe_guard(module, context, binding) do
          {:ok, guardian} when is_pid(guardian) ->
            {:ok, guardian}

          _ ->
            if System.monotonic_time(:millisecond) + @retry < deadline do
              Process.sleep(@retry)
              guard(backend, binding, deadline)
            else
              :error
            end
        end
    end
  end

  defp safe_guard(module, context, binding) do
    module.guard(context, binding)
  rescue
    _ -> {:error, :ingress_unavailable}
  catch
    _, _ -> {:error, :ingress_unavailable}
  end

  defp finish({module, context}, directory, key, reason) do
    outcome = end_with_retries(module, context, key, @end_attempts)
    if outcome == :ended, do: forget(directory, key)
    Lilly.Events.emit("lilly.ingress_bridge_ended", reason: reason, outcome: outcome)
  end

  defp end_with_retries(module, context, key, attempts) do
    case module.end_bridge(context, key) do
      :ok ->
        :ended

      _ when attempts > 1 ->
        Process.sleep(1000)
        end_with_retries(module, context, key, attempts - 1)

      _ ->
        :end_unconfirmed
    end
  end
end
