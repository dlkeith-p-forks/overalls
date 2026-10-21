defmodule Brady.ProxyTest do
  use ExUnit.Case, async: false
  alias Brady.{Cache.Store, HTTP.Stream, Proxy}

  setup do
    root = Path.join(System.tmp_dir!(), "brady-proxy-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    cache =
      start_supervised!(
        {Store,
         root: root, limits: %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}}
      )

    Store.observe(cache, 90, 100, true)
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, origin} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, origin_port}} = :inet.sockname(origin)
    spawn_link(fn -> origin_loop(origin, counter) end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    # Loopback deliberately models an admitted public origin for HTTP transport
    # tests only. Runtime configuration must use Destination.policy/1; these
    # tests do not establish namespace interception or public-address filtering.
    config = %{
      destination_policy: [],
      socket_options: [],
      cache: cache,
      resolver: fn "origin.example" -> {:ok, [{127, 0, 0, 1}]} end
    }

    spawn_link(fn -> proxy_loop(listener, origin_port, config) end)

    on_exit(fn ->
      :gen_tcp.close(origin)
      :gen_tcp.close(listener)
    end)

    %{port: port, origin_port: origin_port, counter: counter, cache: cache}
  end

  defp origin_loop(listener, counter) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request, rest} = Stream.head({:tcp, socket}, :request)
        {:ok, _, _} = Stream.body({:tcp, socket}, request.body, rest, fn _ -> :ok end)
        Agent.update(counter, &(&1 + 1))
        date = :httpd_util.rfc1123_date() |> List.to_string()

        if request.target == "/malformed" do
          :gen_tcp.send(socket, "HTTP/1.1 invalid\r\n\r\n")
        else
          :gen_tcp.send(socket, [
            "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 OK\r\nDate: ",
            date,
            "\r\nCache-Control: public, max-age=600\r\nContent-Length: 4\r\nAlt-Svc: h3=\":443\"\r\n\r\ndata"
          ])
        end

        :gen_tcp.close(socket)
        origin_loop(listener, counter)

      _ ->
        :ok
    end
  end

  defp proxy_loop(listener, origin_port, config) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        Proxy.serve({:tcp, socket}, {{127, 0, 0, 1}, origin_port}, :http, config, %{
          attribution: :resolved
        })

        proxy_loop(listener, origin_port, config)

      _ ->
        :ok
    end
  end

  defp request(context, extra \\ "", target \\ "/image") do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, context.port, [:binary, active: false])

    :gen_tcp.send(
      socket,
      "GET #{target} HTTP/1.1\r\nHost: origin.example:#{context.origin_port}\r\n" <>
        extra <> "\r\n"
    )

    try do
      receive_all(socket, "")
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> receive_all(socket, acc <> bytes)
      {:error, :closed} -> acc
    end
  end

  test "public download reaches cache and later range comes from complete object", context do
    first = request(context)
    assert first =~ "200 OK"
    assert String.ends_with?(first, "data")
    refute first =~ "h3="
    second = request(context, "Range: bytes=1-2\r\n")
    assert second =~ "206 Partial Content"
    assert String.ends_with?(second, "at")
    assert Agent.get(context.counter, & &1) == 1
  end

  test "authentication and signed URLs bypass reuse and storage", context do
    assert request(context) =~ "200 OK"
    assert request(context, "Authorization: Bearer secret\r\n") =~ "200 OK"
    assert request(context, "", "/image?signature=secret") =~ "200 OK"
    assert Agent.get(context.counter, & &1) == 3
    assert Store.stats(context.cache).objects == 1
  end

  test "cache crash preserves proxied upstream retrieval", context do
    stop_supervised!(Store)
    assert request(context) =~ "200 OK"
    assert Agent.get(context.counter, & &1) == 1
  end

  test "only validated completed exchanges enter the SLO denominator", context do
    before = Brady.Metrics.slo_snapshot()
    assert request(context) =~ "200 OK"
    assert request(context, "Host: duplicate.example\r\n") =~ "400"
    after_sample = Brady.Metrics.slo_snapshot()
    assert after_sample.requests - before.requests == 1
    assert after_sample.successes - before.successes == 1
    assert after_sample.failures == before.failures
  end

  test "malformed upstream framing remains a diagnosed admitted failure", context do
    before = Brady.Metrics.slo_snapshot()

    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason, :slo_admitted]], fn ->
        assert request(context, "", "/malformed") == ""
      end)

    assert output =~ "brady.request_completed"
    assert output =~ "invalid_http"
    after_sample = Brady.Metrics.slo_snapshot()
    assert after_sample.requests == before.requests + 1
    assert after_sample.failures == before.failures + 1
    assert after_sample.successes == before.successes
  end
end
