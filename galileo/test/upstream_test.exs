defmodule Galileo.UpstreamTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Galileo.Upstream
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)

  defmodule UploadOrigin do
    @behaviour Plug
    @impl true
    def init(options), do: options

    @impl true
    def call(conn, owner) do
      if String.starts_with?(conn.request_path, "/history/"),
        do: send(owner, {:origin_attempt, conn.request_path}),
        else: send(owner, :origin_attempt)

      if String.starts_with?(conn.request_path, "/history/partial/") do
        partial(conn)
      else
        ordinary(conn, owner)
      end
    end

    @spec partial(Plug.Conn.t()) :: Plug.Conn.t()
    defp partial(conn) do
      ["", "history", "partial", chunks, size] = String.split(conn.request_path, "/")
      {chunks, ""} = Integer.parse(chunks)
      {size, ""} = Integer.parse(size)
      true = chunks in 1..5 and size in 1..256
      conn = Plug.Conn.send_chunked(conn, 200)

      conn =
        Enum.reduce(1..chunks, conn, fn _, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("p", size))
          conn
        end)

      receive do
        :never_sent -> conn
      after
        2000 ->
          case Plug.Conn.chunk(conn, "late") do
            {:ok, conn} -> conn
            {:error, _} -> conn
          end
      end
    end

    @spec ordinary(Plug.Conn.t(), pid()) :: Plug.Conn.t()
    defp ordinary(conn, owner) do
      if conn.request_path == "/stall" do
        receive do
          :never_sent -> Plug.Conn.send_resp(conn, 200, "late")
        after
          2_000 -> Plug.Conn.send_resp(conn, 200, "late")
        end
      else
        consume(conn, owner, 0)
      end
    end

    defp consume(conn, owner, count) do
      case Plug.Conn.read_body(conn, length: 16_384, read_length: 16_384) do
        {:more, bytes, conn} ->
          send(owner, {:origin_chunk, byte_size(bytes)})
          consume(conn, owner, count + byte_size(bytes))

        {:ok, bytes, conn} ->
          send(owner, {:origin_chunk, byte_size(bytes)})
          Plug.Conn.send_resp(conn, 200, Integer.to_string(count + byte_size(bytes)))
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-partial-response-cutoff
  # Generated partial response prefixes MUST survive unchanged before refusal,
  # invalid renewal, expiry or consumer halt. No late bytes or replay may be
  # delivered after the single attempt returns cancelled.
  property "partial responses stop at lease or consumer cancellation", %{origin: origin} do
    check all(
            chunks <- integer(1..5),
            size <- integer(1..256),
            terminal <- member_of([:refused, :invalid, :expired, :halt]),
            max_runs: 8
          ) do
      owner = self()
      nonce = make_ref()
      path = "/history/partial/#{chunks}/#{size}"

      result =
        Upstream.stream(%{target: origin, headers: [], ttl: 600},
          method: "GET",
          path: path,
          query: "",
          body_state: :empty,
          pull: fn state -> {:ok, "", state} end,
          headers: [],
          consume: fn
            {:data, bytes} ->
              send(owner, {:partial_data, nonce, bytes})
              if terminal == :halt, do: :halt, else: :ok

            _ ->
              :ok
          end,
          renew: fn ->
            case terminal do
              :refused -> {:error, :unauthorized}
              :invalid -> {:ok, %{ttl: 0}}
              :expired -> Process.sleep(1200)
              :halt -> {:ok, %{ttl: 600}}
            end
          end,
          transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
        )

      delivered = delivered_partial(nonce, [])
      expected = String.duplicate("p", size * chunks)
      assert result.outcome == :cancelled
      assert result.status == 200
      assert result.response_bytes == byte_size(delivered)
      assert byte_size(delivered) > 0
      assert String.starts_with?(expected, delivered)
      if terminal != :halt, do: assert(delivered == expected)
      refute_receive {:partial_data, ^nonce, _}, 100
      assert_receive {:origin_attempt, ^path}
      refute_receive {:origin_attempt, ^path}, 100
    end
  end

  @spec delivered_partial(reference(), [binary()]) :: binary()
  defp delivered_partial(nonce, chunks) do
    receive do
      {:partial_data, ^nonce, bytes} -> delivered_partial(nonce, [bytes | chunks])
    after
      0 -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  setup do
    origin =
      start_supervised!(
        {Bandit,
         plug: {UploadOrigin, self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(origin)
    %{origin: "https://localhost:#{port}"}
  end

  defp authorization(headers, peer \\ nil),
    do: %{
      target: "https://api.example.test",
      strip_prefix: nil,
      headers: headers,
      peer: peer,
      ttl: 5000
    }

  test "injected headers override guest duplicates and strip transport headers" do
    guest = [
      {"authorization", "Bearer guest-attempt"},
      {"x-api-token", "guest"},
      {"host", "evil.test"},
      {"content-length", "999"},
      {"connection", "keep-alive"},
      {"x-forwarded-for", "1.2.3.4"},
      {"accept", "text/plain"},
      {"content-type", "application/json"}
    ]

    authorization = authorization([{"authorization", "Bearer platform"}, {"x-api-token", "sk-1"}])
    headers = Upstream.headers(authorization, guest)

    assert {"authorization", "Bearer platform"} in headers
    assert {"x-api-token", "sk-1"} in headers
    refute {"authorization", "Bearer guest-attempt"} in headers
    refute {"x-api-token", "guest"} in headers

    refute Enum.any?(headers, fn {name, _} -> name in ["host", "content-length", "connection"] end)

    refute Enum.any?(headers, fn {name, _} -> String.starts_with?(name, "x-forwarded") end)
    assert {"content-type", "application/json"} in headers
    assert {"accept", "text/plain"} in headers
    assert Upstream.origin(authorization) == "https://api.example.test"
  end

  test "peer requests carry only the canonical host and platform token" do
    token = "galileo_peer_" <> String.duplicate("a", 43)
    peer = %{endpoint: "https://bob.example.test", token: token}
    authorization = authorization([{"authorization", "Bearer x"}], peer)

    headers =
      Upstream.headers(authorization, [{"authorization", "guest"}, {"accept", "text/html"}])

    assert headers == [{"host", "bob.example.test"}, {"authorization", "galileo-peer " <> token}]
    assert Upstream.origin(authorization) == "https://bob.example.test"
  end

  property "guest headers never override injected names regardless of case" do
    check all(
            name <-
              member_of(["Authorization", "AUTHORIZATION", "authorization", "aUtHoRiZaTiOn"]),
            value <- string(:alphanumeric, min_length: 1, max_length: 16)
          ) do
      authorization = authorization([{"authorization", "Bearer platform"}])
      headers = Upstream.headers(authorization, [{name, value}])

      assert Enum.count(headers, fn {header_name, _} ->
               String.downcase(header_name) == "authorization"
             end) == 1
    end
  end

  test "uploads are pulled incrementally on one verified TLS attempt", %{origin: origin} do
    chunks = [:binary.copy(<<1>>, 65_536), :binary.copy(<<2>>, 65_536), "tail"]
    owner = self()

    pull = fn
      [] ->
        {:ok, "", []}

      [last] ->
        send(owner, {:pulled, last})
        {:ok, last, []}

      [next | rest] ->
        send(owner, {:pulled, next})
        {:more, next, rest}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: chunks,
        pull: pull,
        headers: [{"content-length", Integer.to_string(Enum.sum(Enum.map(chunks, &byte_size/1)))}],
        consume: fn event ->
          send(owner, event)
          :ok
        end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :completed
    assert result.status == 200
    assert result.body_state == []
    assert_receive :origin_attempt
    refute_receive :origin_attempt
    assert_receive {:pulled, first}
    assert byte_size(first) == 65_536
    assert_receive {:pulled, second}
    assert byte_size(second) == 65_536
    assert_receive {:pulled, "tail"}
    assert_receive {:data, "131076"}
  end

  test "owner-bound sources require cancellation before any origin or body effect", %{
    origin: origin
  } do
    owner = self()

    assert_raise ArgumentError, "owner-bound source requires frontend cancellation", fn ->
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :empty,
        pull_in_owner: true,
        pull: fn state ->
          send(owner, :source_pulled)
          {:ok, "", state}
        end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )
    end

    refute_receive :source_pulled
    refute_receive :origin_attempt
  end

  test "an upload lasting beyond a short lease renews the same attempt", %{origin: origin} do
    owner = self()

    pull = fn
      0 ->
        Process.sleep(300)
        {:more, :binary.copy(<<1>>, 32_768), 1}

      1 ->
        Process.sleep(300)
        {:more, :binary.copy(<<2>>, 32_768), 2}

      2 ->
        Process.sleep(300)
        {:ok, "tail", 3}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: 0,
        pull: pull,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn ->
          send(owner, :upload_renewed)
          {:ok, %{ttl: 500}}
        end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :completed
    assert result.body_state == 3
    assert_receive :origin_attempt
    assert_receive :upload_renewed
    assert_receive :upload_renewed
    refute_receive :origin_attempt
  end

  test "renewal refusal during upload closes the same attempt without retry", %{origin: origin} do
    owner = self()

    pull = fn
      :first ->
        {:more, :binary.copy(<<1>>, 32_768), :blocked}

      :blocked ->
        send(owner, :upload_blocked)
        Process.sleep(400)
        {:ok, :binary.copy(<<2>>, 32_768), :finished}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :first,
        pull: pull,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn ->
          send(owner, :upload_renewal_refused)
          {:error, :unauthorized}
        end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :cancelled
    assert result.body_state == :blocked
    assert_receive :origin_attempt
    assert_receive :upload_blocked
    assert_receive :upload_renewal_refused
    refute_receive :origin_attempt, 200
  end

  test "source failure aborts without retrying the authorized request", %{origin: origin} do
    pull = fn
      :first -> {:more, :binary.copy(<<1>>, 65_536), :truncate}
      :truncate -> {:error, :truncated}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :first,
        pull: pull,
        headers: [{"content-length", "131072"}],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :source_error
    assert result.body_state == :truncate
    # Bandit may dispatch before or after receiving the complete body. Either way,
    # there can be at most the one connection created before source truncation.
    receive do
      :origin_attempt -> :ok
    after
      50 -> :ok
    end

    refute_receive :origin_attempt, 200
    refute_receive {:origin_chunk, 131_072}
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-generated-single-attempt
  # A source failure before, during or after a partial upload MUST NOT replay
  # the same guest-selected path at the local TLS origin's request handler.
  property "generated source failures never replay one upstream request", %{origin: origin},
    profile: :ci do
    check all(
            sizes <-
              list_of(member_of([1, 16_383, 16_384, 16_385, 65_536]),
                min_length: 2,
                max_length: 4
              ),
            max_runs: 12
          ) do
      for mode <- [:before, :middle, :after, :success] do
        path = "/history/" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

        fail_at =
          case mode do
            :before -> 0
            :middle -> div(length(sizes), 2)
            :after -> length(sizes)
            :success -> nil
          end

        pull = fn {index, remaining} ->
          cond do
            index == fail_at ->
              {:error, :truncated}

            remaining == [] ->
              {:ok, "", {index, []}}

            true ->
              [size | rest] = remaining
              bytes = :binary.copy(<<index + 1>>, size)

              if rest == [] and is_nil(fail_at),
                do: {:ok, bytes, {index + 1, rest}},
                else: {:more, bytes, {index + 1, rest}}
          end
        end

        result =
          Upstream.stream(%{target: origin, headers: [], ttl: 5000},
            method: "POST",
            path: path,
            query: "",
            body_state: {0, sizes},
            pull: pull,
            headers: [],
            consume: fn _ -> :ok end,
            renew: fn -> {:ok, %{ttl: 5000}} end,
            transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
          )

        assert result.outcome == if(is_nil(fail_at), do: :completed, else: :source_error)
        {pulled_chunks, _remaining} = result.body_state
        assert pulled_chunks == (fail_at || length(sizes))

        # Upstream.stream/2 is synchronous; count handler dispatches that have
        # arrived by return plus a bounded quiet window for local dispatch.
        attempts = attempt_count(path)
        assert attempts <= 1
        if is_nil(fail_at), do: assert(attempts == 1)
      end
    end
  end

  @spec attempt_count(binary()) :: non_neg_integer()
  defp attempt_count(path) do
    receive do
      {:origin_attempt, ^path} -> 1 + attempt_count(path)
    after
      200 -> 0
    end
  end

  test "TLS verifies the authorized target hostname before pulling body", %{origin: origin} do
    mismatched = String.replace(origin, "localhost", "localhost.localdomain")
    owner = self()

    result =
      Upstream.stream(%{target: mismatched, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :unread,
        pull: fn state ->
          send(owner, :body_pulled)
          {:ok, "secret", state}
        end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :transport_error
    assert result.body_state == :unread
    refute_receive :body_pulled
    refute_receive :origin_attempt
  end

  test "a refused renewal cancels one stalled upstream attempt", %{origin: origin} do
    owner = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           Upstream.stream(%{target: origin, headers: [], ttl: 500},
             method: "GET",
             path: "/stall",
             query: "",
             body_state: :empty,
             pull: fn state -> {:ok, "", state} end,
             headers: [],
             consume: fn _ -> :ok end,
             renew: fn ->
               send(owner, {:renewed, System.monotonic_time(:millisecond)})
               {:error, :unauthorized}
             end,
             transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
           )

         send(owner, {:result, result})
       end}
    )

    assert_receive :origin_attempt, 1000
    assert_receive {:renewed, refused_at}, 1000
    assert_receive {:result, %{outcome: :cancelled}}, 1000
    assert System.monotonic_time(:millisecond) - refused_at < 750
    refute_receive :origin_attempt
  end

  test "a silent upstream remains open across response polling intervals while renewals succeed",
       %{
         origin: origin
       } do
    owner = self()

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "GET",
        path: "/stall",
        query: "",
        body_state: :empty,
        pull: fn state -> {:ok, "", state} end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn ->
          send(owner, :silent_renewed)
          {:ok, %{ttl: 500}}
        end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :completed
    assert result.status == 200
    assert_receive :origin_attempt
    assert_receive :silent_renewed
    assert_receive :silent_renewed
    assert_receive :silent_renewed
    refute_receive :origin_attempt
  end

  test "a renewal call cannot outlive the current lease", %{origin: origin} do
    owner = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           Upstream.stream(%{target: origin, headers: [], ttl: 500},
             method: "GET",
             path: "/stall",
             query: "",
             body_state: :empty,
             pull: fn state -> {:ok, "", state} end,
             headers: [],
             consume: fn _ -> :ok end,
             renew: fn ->
               send(owner, :renewal_started)

               receive do
                 :never_sent -> {:ok, %{ttl: 500}}
               end
             end,
             transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
           )

         send(owner, {:late_result, result})
       end}
    )

    assert_receive :origin_attempt, 1000
    assert_receive :renewal_started, 1000
    assert_receive {:late_result, %{outcome: :cancelled}}, 1000
    refute_receive :origin_attempt
  end

  # @cc [owner:ghuntley,label:verification;security] generated-galileo-lease-cutoff
  # After zero or one valid renewals, refusal, an invalid TTL or a renewal
  # blocked beyond expiry MUST cancel the one TLS attempt without response data.
  property "generated renewal histories close one upstream attempt", %{origin: origin},
    profile: :ci do
    check all(ttl <- integer(600..700), valid_prefix <- integer(0..1), max_runs: 4) do
      for terminal <- [:refused, :invalid, :expired] do
        owner = self()
        calls = :atomics.new(1, [])

        result =
          Upstream.stream(%{target: origin, headers: [], ttl: ttl},
            method: "GET",
            path: "/stall",
            query: "",
            body_state: :empty,
            pull: fn state -> {:ok, "", state} end,
            headers: [],
            consume: fn event ->
              send(owner, {:upstream_event, event})
              :ok
            end,
            renew: fn ->
              call = :atomics.add_get(calls, 1, 1)

              if call <= valid_prefix do
                {:ok, %{ttl: ttl}}
              else
                case terminal do
                  :refused -> {:error, :unauthorized}
                  :invalid -> {:ok, %{ttl: 499}}
                  :expired -> Process.sleep(ttl * 2)
                end
              end
            end,
            transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
          )

        assert result.outcome == :cancelled
        assert result.status == nil
        assert result.response_bytes == 0
        assert :atomics.get(calls, 1) == valid_prefix + 1
        assert_receive :origin_attempt, 1000
        refute_receive {:upstream_event, {:data, _}}
        refute_receive :origin_attempt, 100
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] stalled-upload-lease-termination
  # Generated refused, invalid and expired renewals MUST finish the streaming
  # caller and terminate a blocked source reader without another upstream attempt
  # or body delivery. The reader handshake, not elapsed time, proves it blocked.
  property "lease cancellation terminates a stalled upload reader", %{origin: origin},
    profile: :ci do
    check all(
            terminal <- member_of([:refused, :invalid, :expired]),
            owner_bound <- boolean(),
            max_runs: 12
          ) do
      owner = self()
      nonce = make_ref()

      {caller, monitor} =
        spawn_monitor(fn ->
          stream_owner = self()

          result =
            Upstream.stream(%{target: origin, headers: [], ttl: 600},
              method: "POST",
              path: "/upload",
              query: "",
              body_state: :blocked,
              pull_in_owner: owner_bound,
              cancel_frontend: fn ->
                send(owner, {:frontend_cancelled, nonce})
                send(stream_owner, {:release, nonce})
                :ok
              end,
              pull: fn _ ->
                send(owner, {:reader_blocked, nonce, self()})

                receive do
                  {:release, ^nonce} -> {:ok, "late", :done}
                end
              end,
              headers: [],
              consume: fn event ->
                send(owner, {:delivered, nonce, event})
                :ok
              end,
              renew: fn ->
                case terminal do
                  :refused ->
                    {:error, :unauthorized}

                  :invalid ->
                    {:ok, %{ttl: 0}}

                  :expired ->
                    receive do
                      :never -> {:ok, %{ttl: 600}}
                    end
                end
              end,
              transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
            )

          send(owner, {:stream_result, nonce, result})
        end)

      try do
        assert_receive {:reader_blocked, ^nonce, reader}, 2000
        reader_monitor = Process.monitor(reader)
        assert_receive {:stream_result, ^nonce, %{outcome: :cancelled, response_bytes: 0}}, 2000
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1000
        assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _}, 1000
        assert_receive {:frontend_cancelled, ^nonce}, 1000
        refute_receive {:frontend_cancelled, ^nonce}
        refute_receive {:delivered, ^nonce, _}
        assert_receive :origin_attempt, 1000
        refute_receive :origin_attempt, 100
      after
        if Process.alive?(caller), do: Process.exit(caller, :kill)
      end
    end
  end
end
