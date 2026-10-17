defmodule Brady.Cache.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Brady.Cache.Policy
  @now 1_600_000_000
  @headers [{"date", "Sun, 13 Sep 2020 12:26:40 GMT"}, {"cache-control", "public, max-age=600"}]

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        method: "GET",
        scheme: :https,
        host: "packages.example",
        port: 443,
        target: "/archive.tar",
        headers: []
      },
      overrides
    )
  end

  test "explicit public freshness includes response delay and upstream age" do
    assert {:ok, entry} =
             Policy.admit(request(), 200, @headers ++ [{"age", "100"}], @now, @now + 10)

    assert entry.initial_age == 110
    assert entry.expires_at == @now + 500
    assert Policy.fresh?(entry, @now + 499)
    refute Policy.fresh?(entry, @now + 500)
    refute Policy.fresh?(entry, @now - 1)
    assert Policy.current_age(entry, @now + 20) == 120
  end

  test "credentials, personalized responses, signed URLs and ambiguity bypass" do
    for name <-
          ~w(Authorization Proxy-Authorization X-API-Key X-Auth-Token Cookie Range If-Range Cache-Control Pragma) do
      assert :bypass ==
               Policy.admit(request(%{headers: [{name, "secret"}]}), 200, @headers, @now, @now)
    end

    for name <- ~w(Set-Cookie Content-Range WWW-Authenticate) do
      assert :bypass == Policy.admit(request(), 200, @headers ++ [{name, "secret"}], @now, @now)
    end

    for suffix <- ["?signature=secret", "?page=2", "#secret"] do
      refute Policy.eligible?(request(%{target: "/archive" <> suffix}))
    end

    for directive <- [
          "private",
          "no-store",
          "no-cache",
          "max-age=100",
          "public",
          "must-understand"
        ] do
      assert :bypass ==
               Policy.admit(
                 request(),
                 200,
                 @headers ++ [{"cache-control", directive}],
                 @now,
                 @now
               )
    end

    assert :bypass == Policy.admit(request(), 206, @headers, @now, @now)
    assert :bypass == Policy.admit(request(), 200, @headers ++ [{"vary", "*"}], @now, @now)
    assert :bypass == Policy.admit(request(), 200, @headers ++ [{"date", "bad"}], @now, @now)
    assert :bypass == Policy.admit(request(), 200, @headers ++ [{"age", "600"}], @now, @now)
  end

  property "origins, targets and variant values never alias in exercised identities" do
    check all(part <- string(:alphanumeric, min_length: 1, max_length: 100)) do
      base = request()
      key = Policy.key(base, ["accept-encoding"])

      for modified <- [
            request(%{scheme: :http}),
            request(%{port: 8443}),
            request(%{host: part <> ".other.example"}),
            request(%{target: "/other/" <> part}),
            request(%{headers: [{"accept-encoding", part}]})
          ] do
        refute Policy.key(modified, ["accept-encoding"]) == key
      end

      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, key)
    end
  end

  test "missing and empty variants differ; names and host are case insensitive" do
    refute Policy.key(request(), ["accept-encoding"]) ==
             Policy.key(request(%{headers: [{"Accept-Encoding", ""}]}), ["accept-encoding"])

    assert Policy.key(request(), []) == Policy.key(request(%{host: "PACKAGES.EXAMPLE"}), [])
  end
end
