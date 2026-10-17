defmodule Brady.Cache.ArchivePolicyHistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Brady.Cache.Policy

  @now 1_700_000_000
  @date "Tue, 14 Nov 2023 22:13:20 GMT"
  @type selection :: {[{String.t(), String.t()}], boolean()}

  # @cc [owner:ghuntley,label:verification;security] archive-policy-combinations
  # Inferred freshness MUST require a canonical anonymous pinned archive.
  # Contradictory controls and unsupported or repeated Vary fields MUST refuse
  # admission in combination. Accepted variants MUST distinguish missing, empty
  # and distinct values independently of Authorization Vary normalization.
  property "pinned archive combinations preserve refusals and exact variant identity" do
    check all(
            commit <- binary(length: 20),
            legacy <- boolean(),
            control <- member_of(controls()),
            vary <- member_of(variations()),
            variant <- member_of(["", "gzip", "identity"]),
            max_runs: 30
          ) do
      revision = Base.encode16(commit, case: :lower)
      archive = if legacy, do: "legacy.tar.gz", else: "tar.gz"

      request = %{
        method: "GET",
        scheme: :https,
        host: "codeload.github.com",
        port: 443,
        target: "/owner/repository/#{archive}/#{revision}",
        headers: []
      }

      for {{controls, controls_ok}, {fields, vary_ok}} <- [
            {control, vary},
            {{[], true}, {[{"vary", "Authorization, Accept-Encoding"}], true}},
            {{[{"cache-control", "max-age=600, private"}], false}, {[], true}},
            {{[{"cache-control", "max-age=600, no-store"}], false}, {[], true}},
            {{[{"cache-control", "max-age=600, max-age=600"}], false}, {[], true}},
            {{[], true}, {[{"vary", "Authorization, Authorization"}], false}},
            {{[], true}, {[{"vary", "Authorization, Cookie"}], false}},
            {{[], true}, {[{"vary", "*"}], false}}
          ] do
        headers = [{"date", @date}] ++ controls ++ fields
        result = Policy.admit(request, 200, headers, @now, @now)

        if controls_ok and vary_ok do
          assert {:ok, entry} = result
          lifetime = if controls == [], do: 3600, else: 600
          assert entry.lifetime == lifetime
          assert entry.initial_age == 0
          assert entry.expires_at == @now + lifetime
          assert Policy.fresh?(entry, @now + lifetime - 1)
          refute Policy.fresh?(entry, @now + lifetime)
          refute Policy.fresh?(entry, @now - 1)
          refute "authorization" in entry.vary

          if "accept-encoding" in entry.vary do
            variants = [
              [],
              [{"accept-encoding", ""}],
              [{"accept-encoding", "gzip"}],
              [{"accept-encoding", "identity"}]
            ]

            keys =
              Enum.map(variants, fn values ->
                assert {:ok, admitted} =
                         Policy.admit(%{request | headers: values}, 200, headers, @now, @now)

                admitted.key
              end)

            assert length(Enum.uniq(keys)) == length(variants)

            assert {:ok, selected} =
                     Policy.admit(
                       %{request | headers: [{"accept-encoding", variant}]},
                       200,
                       headers,
                       @now,
                       @now
                     )

            index = Enum.find_index(variants, &(&1 == [{"accept-encoding", variant}]))
            assert selected.key == Enum.at(keys, index)
          end
        else
          assert :bypass = result
        end
      end

      inferred = [{"date", @date}, {"vary", "Authorization, Accept-Encoding"}]

      for denied <- [
            %{request | scheme: :http},
            %{request | port: 8443},
            %{request | host: "github.com"},
            %{request | method: "POST"},
            %{request | target: request.target <> "?download=1"},
            %{request | target: request.target <> "/"},
            %{request | target: "/owner/../#{archive}/#{revision}"},
            %{request | target: "/owner/repository/#{archive}/main"},
            %{request | target: "/owner/repository/#{archive}/" <> String.duplicate("A", 40)},
            %{request | target: "/owner/%2e%2e/#{archive}/#{revision}"},
            %{
              request
              | target: "/" <> String.duplicate("o", 40) <> "/repository/#{archive}/#{revision}"
            },
            %{
              request
              | target: "/owner/" <> String.duplicate("r", 101) <> "/#{archive}/#{revision}"
            },
            %{request | headers: [{"authorization", "fixture"}]},
            %{request | headers: [{"cookie", "fixture"}]}
          ] do
        assert :bypass = Policy.admit(denied, 200, inferred, @now, @now)
      end

      for {owner, repository} <- [
            {"o", "r"},
            {String.duplicate("o", 39), String.duplicate("r", 100)}
          ] do
        boundary = %{request | target: "/#{owner}/#{repository}/#{archive}/#{revision}"}
        assert {:ok, entry} = Policy.admit(boundary, 200, inferred, @now, @now)
        assert entry.expires_at == @now + 3600

        assert {:ok, aged} =
                 Policy.admit(boundary, 200, inferred ++ [{"age", "3599"}], @now, @now)

        assert aged.initial_age == 3599
        assert aged.expires_at == @now + 1
        assert :bypass = Policy.admit(boundary, 200, inferred ++ [{"age", "3600"}], @now, @now)
        assert :bypass = Policy.admit(boundary, 200, inferred, @now, @now + 3600)
      end
    end
  end

  @spec controls() :: [selection()]
  defp controls do
    [
      {[], true},
      {[{"cache-control", "max-age=600"}], true},
      {[{"cache-control", "public, max-age=600"}], true},
      {[{"cache-control", "max-age=600, no-store"}], false},
      {[{"cache-control", "max-age=600, private"}], false},
      {[{"cache-control", "max-age=600"}, {"cache-control", "max-age=601"}], false},
      {[{"cache-control", "public, public, max-age=600"}], false},
      {[{"cache-control", "max-age=0"}], false}
    ]
  end

  @spec variations() :: [selection()]
  defp variations do
    [
      {[], true},
      {[{"vary", "Authorization"}], true},
      {[{"vary", "Authorization, Accept-Encoding"}], true},
      {[{"vary", "Accept-Encoding"}, {"vary", "Authorization"}], true},
      {[{"vary", "Authorization, Cookie"}], false},
      {[{"vary", "*"}], false},
      {[{"vary", "Accept-Encoding, accept-encoding"}], false},
      {[{"vary", "Authorization"}, {"vary", "authorization"}], false}
    ]
  end
end
