Code.require_file("peer.ex", __DIR__)

defmodule OverallsAntithesis.ControlPeer.Runner do
  @moduledoc "Real shared Control client against a socket-observed loopback peer."

  alias OverallsAntithesis.ControlPeer, as: Peer
  alias OverallsProtocol.Control.Client

  @type result :: %{required(String.t()) => boolean() | integer()}

  # @cc [owner:ghuntley,label:verification] control-peer-result-boundary
  # A PASS result MUST be derived from peer-observed complete request frames
  # and caller results. Missing frames, failed barriers or lost caller results
  # MUST be reported as unavailable rather than converted to a passing bound.
  @spec main([String.t()]) :: non_neg_integer()
  def main([mode, limit_text, timeout_text]) do
    Process.flag(:trap_exit, true)

    with {limit, ""} <- Integer.parse(limit_text),
         {timeout, ""} <- Integer.parse(timeout_text),
         true <- limit in [0, 1, 8, 64, 255, 256, 257],
         true <- timeout in [50, 500, 5_000] do
      try do
        result =
          case mode do
            "capacity" -> capacity(limit)
            "pending" -> pending(limit, timeout)
            "delivery" -> delivery(limit)
            "version_refusal" -> version_refusal(limit, timeout)
            _ -> throw(:unavailable)
          end

        emit("observed", result)
        0
      rescue
        _ ->
          emit("unavailable", %{})
          0
      catch
        _, _ ->
          emit("unavailable", %{})
          0
      end
    else
      _ ->
        emit("unavailable", %{})
        0
    end
  end

  def main(_),
    do:
      (
        emit("unavailable", %{})
        0
      )

  @spec capacity(integer()) :: result()
  defp capacity(advertised) do
    expected = if advertised in 1..256, do: advertised, else: 8
    {client, server} = open(advertised)

    tasks =
      for nonce <- 1..expected do
        {nonce,
         Task.async(fn ->
           Client.request(client, "galileo.renew", %{"nonce" => nonce}, 15_000)
         end)}
      end

    inventory = inventory(server, expected)
    unique = length(Enum.uniq_by(inventory, fn {id, _} -> id end)) == expected
    complete = Enum.map(inventory, &elem(&1, 1)) |> Enum.sort() == Enum.to_list(1..expected)
    busy = Client.request(client, "galileo.renew", %{"nonce" => 999}, 500)
    require!(Peer.barrier(server, 81))
    no_busy_frame = Peer.no_request?(server)

    Enum.each(Enum.reverse(inventory), fn {id, nonce} -> Peer.response(server, id, nonce) end)
    require!(Peer.barrier(server, 82))

    matching =
      Enum.all?(tasks, fn {nonce, task} ->
        task_result(task, 5_000) == {:ok, %{"nonce" => nonce}}
      end)

    # Reconnect applies a replacement window and must not replay retired IDs.
    Peer.drop(server)
    require!(Peer.await_disconnected(client))
    {:ok, successor} = Peer.await_connection(client, 6_000)
    replacement = if expected == 1, do: 8, else: 1
    Peer.welcome(successor, %{"in_flight" => replacement})
    require!(Peer.await_ready(client))
    require!(Peer.barrier(successor, 83))
    no_replay = Peer.no_request?(successor)

    fresh =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 1_000}, 5_000) end)

    {:ok, new_id, 1_000} = Peer.await_request(successor)
    Peer.response(successor, new_id, 1_000)
    fresh_ok = task_result(fresh, 5_000) == {:ok, %{"nonce" => 1_000}}
    unique_across_reconnect = Enum.all?(inventory, fn {id, _} -> id != new_id end)

    %{
      "limit" => expected,
      "observed" => length(inventory),
      "inventory_complete" => complete,
      "wire_ids_unique" => unique and unique_across_reconnect,
      "busy" => busy == {:error, :busy},
      "busy_no_frame" => no_busy_frame,
      "matching" => matching,
      "no_replay" => no_replay,
      "fresh" => fresh_ok
    }
  end

  @spec pending(integer(), pos_integer()) :: result()
  defp pending(advertised, timeout) do
    {client, server} = open(advertised)

    first =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 101}, timeout) end)

    second =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 102}, 10_000) end)

    inventory = inventory(server, 2)
    ids = Map.new(inventory, fn {id, nonce} -> {nonce, id} end)
    require!(map_size(ids) == 2)
    Peer.response(server, 0, -1)
    Peer.response(server, ids[102], 102)
    Peer.response(server, ids[102], -2)
    require!(Peer.barrier(server, 91))
    second_matching = task_result(second, 2_000) == {:ok, %{"nonce" => 102}}
    first_timeout = task_result(first, timeout + 1_500) == {:error, :timeout}
    Peer.response(server, ids[101], -3)
    require!(Peer.barrier(server, 92))

    fresh =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 103}, 5_000) end)

    {:ok, fresh_id, 103} = Peer.await_request(server)
    Peer.response(server, ids[101], -4)
    require!(Peer.barrier(server, 93))
    Peer.response(server, fresh_id, 103)
    fresh_matching = task_result(fresh, 2_000) == {:ok, %{"nonce" => 103}}

    lost =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 104}, 10_000) end)

    {:ok, lost_id, 104} = Peer.await_request(server)
    Peer.drop(server)
    require!(Peer.await_disconnected(client))
    lost_unproven = task_result(lost, 2_000) == {:error, :unproven}
    {:ok, successor} = Peer.await_connection(client, 6_000)
    Peer.welcome(successor, %{"in_flight" => 8})
    require!(Peer.await_ready(client))
    require!(Peer.barrier(successor, 94))
    no_replay = Peer.no_request?(successor)

    sentinel =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 105}, 5_000) end)

    {:ok, sentinel_id, 105} = Peer.await_request(successor)
    Peer.response(successor, sentinel_id, 105)
    sentinel_matching = task_result(sentinel, 2_000) == {:ok, %{"nonce" => 105}}

    %{
      "distinct_ids" =>
        MapSet.size(MapSet.new([ids[101], ids[102], fresh_id, lost_id, sentinel_id])) == 5,
      "reordered_matching" => second_matching,
      "timeout_retired" => first_timeout,
      "late_ignored" => fresh_matching,
      "loss_unproven" => lost_unproven,
      "no_replay" => no_replay,
      "sentinel_matching" => sentinel_matching
    }
  end

  @spec delivery(integer()) :: result()
  defp delivery(advertised) do
    {client, server} = open(advertised)

    call =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 201}, 10_000) end)

    {:ok, first_id, 201} = Peer.await_request(server)
    require!(Peer.barrier(server, 97))
    first_count = if Peer.no_request?(server), do: 1, else: 2
    Peer.drop(server)
    require!(Peer.await_disconnected(client))
    uncertain = task_result(call, 2_000) == {:error, :unproven}

    {:ok, successor} = Peer.await_connection(client, 6_000)
    Peer.welcome(successor, %{"in_flight" => 8})
    require!(Peer.await_ready(client))
    require!(Peer.barrier(successor, 95))
    first_quiet = Peer.no_request?(successor)
    Peer.drop(successor)
    require!(Peer.await_disconnected(client))
    {:ok, third} = Peer.await_connection(client, 6_000)
    Peer.welcome(third, %{"in_flight" => 8})
    require!(Peer.await_ready(client))
    require!(Peer.barrier(third, 96))
    second_quiet = Peer.no_request?(third)

    sentinel =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 202}, 5_000) end)

    {:ok, sentinel_id, 202} = Peer.await_request(third)
    Peer.response(third, sentinel_id, 202)
    require!(Peer.barrier(third, 98))
    sentinel_count = if Peer.no_request?(third), do: 1, else: 2
    acknowledged = task_result(sentinel, 2_000) == {:ok, %{"nonce" => 202}}

    %{
      "first_frame_count" => first_count,
      "old_frame_count_after_reconnect" => if(first_quiet and second_quiet, do: 0, else: 1),
      "recovered_handshakes" => 2,
      "sentinel_count" => sentinel_count,
      "uncertain" => uncertain,
      "sentinel_ack" => acknowledged,
      "distinct_ids" => first_id != sentinel_id
    }
  end

  # @cc [owner:ghuntley,label:verification] control-peer-version-refusal
  # The version refusal mode MUST hold one peer-observed request across a
  # welcomed 4001 close, then count transport accepts for longer than the
  # client's maximum reconnect backoff. The quiet window is finite evidence of
  # no retry; it MUST NOT be reported as a proof that the client never retries.
  # Quiet window: the client's backoff ceiling is 4_000 ms and its first
  # recoverable retry fires within 1_000 ms.
  @version_refusal_quiet_ms 5_000

  @spec version_refusal(integer(), pos_integer()) :: result()
  defp version_refusal(advertised, hold) do
    {client, server} = open(advertised)

    held =
      Task.async(fn -> Client.request(client, "galileo.renew", %{"nonce" => 301}, 30_000) end)

    {:ok, _held_id, 301} = Peer.await_request(server)
    Process.sleep(hold)
    Peer.flush_accepted()
    Peer.close_with(server, 4001)
    {:ok, reason} = Peer.await_disconnect_reason(client, 5_000)
    held_result = task_result(held, 2_000)
    handshakes = Peer.handshakes_within(@version_refusal_quiet_ms)
    status = Client.status(client)
    post = Client.request(client, "galileo.renew", %{"nonce" => 302}, 500)

    %{
      "close_class" => reason == :unsupported_version,
      "pending_unproven" => held_result == {:error, :unproven},
      "status_retained" => status == {:disconnected, :unsupported_version},
      "handshakes_after_refusal" => handshakes,
      "quiet_ms" => @version_refusal_quiet_ms,
      "post_refusal_disconnected" => post == {:error, :disconnected},
      "client_alive" => Process.alive?(client)
    }
  end

  @spec open(integer()) :: {pid(), pid()}
  defp open(advertised) do
    {:ok, port, _acceptor} = Peer.start(self())
    {:ok, client} = Peer.client(port, self())
    {:ok, server} = Peer.await_connection(client)
    Peer.welcome(server, %{"in_flight" => advertised})
    require!(Peer.await_ready(client))
    {client, server}
  end

  @spec inventory(pid(), non_neg_integer()) :: [{non_neg_integer(), integer()}]
  defp inventory(server, count) do
    for _ <- 1..count do
      {:ok, id, nonce} = Peer.await_request(server)
      {id, nonce}
    end
  end

  @spec task_result(Task.t(), timeout()) :: term()
  defp task_result(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :unavailable
    end
  end

  @spec require!(boolean()) :: :ok
  defp require!(true), do: :ok
  defp require!(false), do: throw(:unavailable)

  @spec emit(String.t(), result()) :: :ok
  defp emit(status, result) do
    fields =
      result
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)

    IO.puts(Enum.join(["RESULT", status | fields], "\t"))
    :ok
  end
end

System.halt(OverallsAntithesis.ControlPeer.Runner.main(System.argv()))
