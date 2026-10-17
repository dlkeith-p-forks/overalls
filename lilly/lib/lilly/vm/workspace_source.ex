defmodule Lilly.VM.WorkspaceSource do
  @moduledoc """
  Boot-bound hand-off of a public provider workspace reference to the guest (ADR-0157).

  Lilly only delivers the closed reference over the jail's Firecracker vsock
  socket; the guest stores it and runs `git clone` itself. Lilly never fetches
  code, touches the guest disk or waits for the clone, and delivery runs in a
  supervised task that cannot delay, fail or fence the VM reaching running.
  """
  alias OverallsProtocol.WorkspaceSource, as: Source

  @port 1031
  @maximum_request 4096
  @maximum_reply 512
  @tasks Lilly.VM.WorkspaceSource.Tasks
  @registry Lilly.VM.WorkspaceSource.Registry
  @default_budget 120_000
  @attempt_limit 10_000
  @initial_backoff 100
  @maximum_backoff 5000

  @type expectation :: OverallsProtocol.Readiness.expectation()
  @type attempt :: :accepted | :conflict | :rejected | :unavailable
  @type failure ::
          :workspace_source_conflict
          | :workspace_source_rejected
          | :workspace_source_unconfirmed
          | :workspace_source_fenced
  @type fence :: (-> :ok | {:error, atom()})
  @type option ::
          {:timeout, pos_integer()}
          | {:fence, fence()}
          | {:backoff, pos_integer()}
  @type state :: :pending | :delivering | :delivered | :failed
  @type payload :: %{String.t() => String.t() | integer() | nil}

  @doc "Supervision children started by `Lilly.Application` for asynchronous delivery."
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    [
      Supervisor.child_spec({Registry, keys: :unique, name: @registry}, id: @registry),
      Supervisor.child_spec({Task.Supervisor, name: @tasks}, id: @tasks)
    ]
  end

  # @cc [owner:ghuntley,label:recovery] workspace-clone-never-gates-readiness
  # start/2 MUST return immediately without linking the caller to delivery. At most one
  # delivery task per placement may run, supervised by Lilly's Task.Supervisor rather than
  # the executor task. Delivery outcomes, crashes or an unavailable supervisor MUST NOT
  # delay, fail or fence the VM's running observation (ADR-0128).
  @spec start(OverallsProtocol.uuid(), (-> term())) :: :ok | :already_running | :unavailable
  def start(placement_id, fun) when is_function(fun, 0) do
    if in_flight?(placement_id) do
      :already_running
    else
      try do
        case Task.Supervisor.start_child(@tasks, fn -> run_once(placement_id, fun) end,
               restart: :temporary
             ) do
          {:ok, _pid} -> :ok
          _ -> :unavailable
        end
      catch
        :exit, _ -> :unavailable
      end
    end
  end

  @doc "Whether a delivery task currently owns this placement."
  @spec in_flight?(OverallsProtocol.uuid()) :: boolean()
  def in_flight?(placement_id) do
    try do
      Registry.lookup(@registry, placement_id) != []
    rescue
      ArgumentError -> false
    end
  end

  defp run_once(placement_id, fun) do
    case Registry.register(@registry, placement_id, nil) do
      {:ok, _} -> fun.()
      {:error, {:already_registered, _}} -> :already_running
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] workspace-source-boot-bound
  # deliver/4 MUST bind every request to the exact persisted placement, execution epoch and
  # boot challenge plus a fresh 32-byte nonce, and count only a bounded reply echoing all of
  # them as accepted. The fence MUST pass before every attempt and after acceptance so a
  # superseded boot is never sent a source or recorded as delivered. A conflict or
  # malformed/mismatched reply is terminal; only transport failures retry, within one budget.
  @spec deliver(Path.t(), expectation(), Source.t(), [option()]) :: :ok | {:error, failure()}
  def deliver(path, expected, source, options \\ []) do
    budget = Keyword.get(options, :timeout, @default_budget)
    fence = Keyword.get(options, :fence, fn -> :ok end)
    backoff = Keyword.get(options, :backoff, @initial_backoff)

    if is_binary(path) and valid_expectation?(expected) and Source.valid?(source) and
         is_integer(budget) and budget in 1..600_000 do
      poll(path, expected, source, fence, now() + budget, backoff)
    else
      {:error, :workspace_source_rejected}
    end
  end

  defp poll(path, expected, source, fence, deadline, backoff) do
    with {:budget, true} <- {:budget, remaining(deadline) > 0},
         {:fence, :ok} <- {:fence, fence.()},
         {:attempt, :accepted} <-
           {:attempt, exchange(path, expected, source, min(remaining(deadline), @attempt_limit))},
         {:fence, :ok} <- {:fence, fence.()} do
      :ok
    else
      {:budget, false} ->
        {:error, :workspace_source_unconfirmed}

      {:fence, _} ->
        {:error, :workspace_source_fenced}

      {:attempt, :conflict} ->
        {:error, :workspace_source_conflict}

      {:attempt, :rejected} ->
        {:error, :workspace_source_rejected}

      {:attempt, :unavailable} ->
        Process.sleep(min(backoff, remaining(deadline)))
        poll(path, expected, source, fence, deadline, min(backoff * 2, @maximum_backoff))
    end
  end

  @doc "One bounded handshake, request and reply; a fresh nonce is drawn per attempt."
  @spec exchange(Path.t(), expectation(), Source.t(), non_neg_integer()) :: attempt()
  def exchange(path, expected, source, timeout) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    deadline = now() + timeout

    with {:ok, body} <- request(expected, nonce, source),
         true <- timeout > 0 and byte_size(path) <= 107 do
      connect(path, expected, nonce, body, deadline)
    else
      _ -> :rejected
    end
  end

  defp connect(path, expected, nonce, body, deadline) do
    options = [
      :binary,
      active: false,
      packet: :line,
      packet_size: @maximum_reply,
      send_timeout_close: true
    ]

    case Lilly.Host.Sockets.connect_local(path, options, remaining(deadline)) do
      {:ok, socket} ->
        try do
          with {:transport, :ok} <-
                 {:transport, :inet.setopts(socket, send_timeout: remaining(deadline))},
               {:transport, :ok} <- {:transport, :gen_tcp.send(socket, "CONNECT #{@port}\n")},
               {:transport, {:ok, handshake}} <-
                 {:transport, :gen_tcp.recv(socket, 0, remaining(deadline))},
               {:transport, true} <- {:transport, handshake?(handshake)},
               {:transport, :ok} <- {:transport, :gen_tcp.send(socket, body)},
               {:transport, {:ok, reply}} <-
                 {:transport, :gen_tcp.recv(socket, 0, remaining(deadline))},
               {:transport, true} <- {:transport, remaining(deadline) > 0} do
            reply(reply, expected, nonce)
          else
            {:transport, _} -> :unavailable
          end
        after
          :gen_tcp.close(socket)
        end

      _ ->
        :unavailable
    end
  end

  @doc "The exact newline-terminated request line; the source must already be valid."
  @spec request(expectation(), String.t(), Source.t()) :: {:ok, binary()} | :error
  def request(expected, nonce, source) do
    if valid_expectation?(expected) and nonce?(nonce) and Source.valid?(source) do
      body =
        JSON.encode!(%{
          "version" => 1,
          "placement_id" => expected.placement_id,
          "execution_epoch" => expected.execution_epoch,
          "boot_challenge" => expected.boot_challenge,
          "nonce" => nonce,
          "source" => Source.encode(source)
        }) <> "\n"

      if byte_size(body) <= @maximum_request, do: {:ok, body}, else: :error
    else
      :error
    end
  end

  @doc "Classify one reply line against the binding and nonce that were sent."
  @spec reply(binary(), expectation(), String.t()) :: :accepted | :conflict | :rejected
  def reply(line, expected, nonce) when is_binary(line) do
    with true <- byte_size(line) <= @maximum_reply and String.ends_with?(line, "\n"),
         {:ok, %{"state" => state} = value} when map_size(value) == 6 <- JSON.decode(line),
         true <-
           value == %{
             "version" => 1,
             "state" => state,
             "placement_id" => expected.placement_id,
             "execution_epoch" => expected.execution_epoch,
             "boot_challenge" => expected.boot_challenge,
             "nonce" => nonce
           } do
      case state do
        "accepted" -> :accepted
        "conflict" -> :conflict
        _ -> :rejected
      end
    else
      _ -> :rejected
    end
  end

  def reply(_, _, _), do: :rejected

  @doc "Stable sha256 of the encoded reference; journals record this, never the reference."
  @spec digest(Source.t()) :: String.t()
  def digest(source) do
    revision = Source.encode(source)["revision"]

    [
      2,
      Atom.to_string(source.provider),
      Enum.join(source.namespace, "/"),
      source.repository,
      revision["kind"],
      revision["value"] || ""
    ]
    |> Enum.map_join(<<0>>, &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Journal payload for one boot's delivery state."
  @spec payload(
          OverallsProtocol.uuid(),
          Lilly.VM.Boot.t(),
          state(),
          non_neg_integer(),
          String.t()
        ) ::
          payload()
  def payload(host_id, boot, state, attempts, digest) do
    %{
      "state" => Atom.to_string(state),
      "host_id" => host_id,
      "placement_id" => boot.placement_id,
      "execution_epoch" => boot.execution_epoch,
      "generation" => boot.generation,
      "boot_challenge" => boot.boot_challenge,
      "attempts" => attempts,
      "source_digest" => digest
    }
  end

  @doc "Whether a journal payload belongs to this exact boot and source."
  @spec same_boot?(map() | nil, Lilly.VM.Boot.t(), String.t()) :: boolean()
  def same_boot?(nil, _boot, _digest), do: false

  def same_boot?(payload, boot, digest) do
    payload["placement_id"] == boot.placement_id and
      payload["execution_epoch"] == boot.execution_epoch and
      payload["generation"] == boot.generation and
      payload["boot_challenge"] == boot.boot_challenge and payload["source_digest"] == digest
  end

  @doc "A delivered or failed record for this boot and source ends delivery until the next boot."
  @spec settled?(map() | nil, Lilly.VM.Boot.t(), String.t()) :: boolean()
  def settled?(payload, boot, digest),
    do: same_boot?(payload, boot, digest) and payload["state"] in ["delivered", "failed"]

  defp handshake?("OK " <> suffix) when byte_size(suffix) <= 11 do
    case Integer.parse(suffix) do
      {port, "\n"} when port in 1..4_294_967_295 -> suffix == Integer.to_string(port) <> "\n"
      _ -> false
    end
  end

  defp handshake?(_), do: false

  defp valid_expectation?(
         %{placement_id: id, execution_epoch: epoch, boot_challenge: challenge} = value
       )
       when map_size(value) == 3 do
    match?(
      {:ok, _},
      OverallsProtocol.Readiness.response(%{
        "version" => 1,
        "state" => "ready",
        "placement_id" => id,
        "execution_epoch" => epoch,
        "boot_challenge" => challenge,
        "boot_id" => id
      })
    )
  end

  defp valid_expectation?(_), do: false

  defp nonce?(nonce), do: is_binary(nonce) and Regex.match?(~r/\A[0-9a-f]{64}\z/, nonce)
  defp remaining(deadline), do: max(deadline - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
end
