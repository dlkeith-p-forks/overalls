defmodule Brady.Cache.ArchivePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Brady.Cache.{Archive, Policy}
  @now 1_600_000_000
  @headers [{"date", "Sun, 13 Sep 2020 12:26:40 GMT"}, {"vary", "Authorization,Accept-Encoding"}]

  @spec request(String.t()) :: Policy.request()
  defp request(commit) do
    %{
      method: "GET",
      scheme: :https,
      host: "codeload.github.com",
      port: 443,
      target: "/NixOS/nixpkgs/tar.gz/" <> commit,
      headers: []
    }
  end

  property "only public full-commit archive identities infer bounded freshness" do
    check all(bytes <- binary(length: 20), max_runs: 60) do
      commit = Base.encode16(bytes, case: :lower)
      base = request(commit)

      assert {:ok, %{lifetime: 3600, vary: ["accept-encoding"]}} =
               Policy.admit(base, 200, @headers, @now, @now)

      assert Archive.eligible?(%{base | target: "/other/repository/legacy.tar.gz/" <> commit})

      for modified <- [
            %{base | scheme: :http},
            %{base | port: 8443},
            %{base | host: "codeload.github.com.attacker.test"},
            %{base | target: base.target <> "?token=synthetic"},
            %{base | target: "/NixOS/nixpkgs/tar.gz/master"},
            %{base | target: "/NixOS/../tar.gz/" <> commit},
            %{base | headers: [{"Authorization", "Bearer synthetic"}]},
            %{base | headers: [{"cookie", "synthetic"}]}
          ] do
        refute Archive.eligible?(modified)
        assert :bypass = Policy.admit(modified, 200, @headers, @now, @now)
      end

      for headers <- [
            @headers ++ [{"cache-control", "private, max-age=600"}],
            @headers ++ [{"cache-control", "no-store"}],
            @headers ++ [{"set-cookie", "synthetic"}],
            @headers ++ [{"vary", "Authorization"}],
            @headers ++ [{"vary", "x-secret"}]
          ] do
        assert :bypass = Policy.admit(base, 200, headers, @now, @now)
      end

      assert {:ok, %{lifetime: 60}} =
               Policy.admit(base, 200, @headers ++ [{"cache-control", "max-age=60"}], @now, @now)

      refute Policy.key(base, ["accept-encoding"]) ==
               Policy.key(%{base | headers: [{"accept-encoding", "gzip"}]}, ["accept-encoding"])
    end
  end
end
