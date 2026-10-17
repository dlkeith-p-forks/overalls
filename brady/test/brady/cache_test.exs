defmodule Brady.CacheTest do
  use ExUnit.Case, async: true
  alias Brady.{Cache, Cache.Store}
  @now 1_600_000_000
  @request %{
    method: "GET",
    scheme: :https,
    host: "packages.example",
    port: 443,
    target: "/image",
    headers: []
  }
  @response %{
    status: 200,
    body: {:length, 4},
    headers: [
      {"date", "Sun, 13 Sep 2020 12:26:40 GMT"},
      {"cache-control", "public, max-age=600"},
      {"vary", "accept-encoding"},
      {"etag", ~s("one")}
    ]
  }

  setup do
    root = Path.join(System.tmp_dir!(), "brady-cache-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    limits = %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}
    pid = start_supervised!({Store, root: root, limits: limits})
    Store.observe(pid, 90, 100, true)
    %{cache: pid}
  end

  test "public downloads are reused, with variants and range boundaries preserved", %{
    cache: cache
  } do
    assert :miss = Cache.lookup(cache, @request, @now)
    {:ok, ref} = Cache.begin_write(cache, @request, @response, @now, @now)
    Cache.append(cache, ref, "data")
    Cache.commit(cache, ref)
    {:hit, reader, head, 0, 4} = Cache.lookup(cache, @request, @now + 10)
    assert {"age", "10"} in head.headers
    parent = self()

    assert :ok =
             Cache.stream(cache, reader, 0, 4, fn bytes ->
               send(parent, {:body, bytes})
               :ok
             end)

    assert_receive {:body, "data"}
    Cache.close(cache, reader)

    {:hit, reader, %{status: 206}, 1, 2} =
      Cache.lookup(cache, %{@request | headers: [{"range", "bytes=1-2"}]}, @now + 10)

    Cache.close(cache, reader)

    assert :miss =
             Cache.lookup(cache, %{@request | headers: [{"accept-encoding", "gzip"}]}, @now + 10)

    assert :miss =
             Cache.lookup(cache, %{@request | headers: [{"authorization", "secret"}]}, @now + 10)

    assert :miss = Cache.lookup(cache, %{@request | target: "/image?signature=secret"}, @now + 10)
  end

  test "cache outage and close-delimited responses bypass storage", %{cache: cache} do
    assert :bypass = Cache.begin_write(cache, @request, %{@response | body: :close}, @now, @now)
    stop_supervised!(Store)
    assert :miss = Cache.lookup(cache, @request, @now)
    assert :bypass = Cache.begin_write(cache, @request, @response, @now, @now)
  end
end
