defmodule Marshall.Control.SatelliteVersionTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Control.Services.Ziggy

  @ziggy_routes ~w(admit renew complete authorize update_authorize identity agent_register agent_heartbeat agent_claim agent_transition agent_next agent_result ssh_roster ssh_authorized_keys ssh_host_certificate ssh_authorize ssh_login)

  # @cc [owner:ghuntley,label:verification;protocol] satellite-version-refusal-wire
  # Every Ziggy op MUST answer an explicit wrong body version with
  # unsupported_version before dispatch; a missing version envelope MUST
  # retain its ordinary invalid_request refusal. Galileo carries no body
  # version: its refusal is the control socket's (426 at upgrade, 4001 after
  # hello), covered by the control API tests.
  property "explicit wrong Ziggy body versions receive permanent refusals" do
    check all(version <- member_of([0, 1, 99, "2", nil]), max_runs: 20) do
      for route <- @ziggy_routes do
        assert Ziggy.handle_request("ziggy." <> route, %{"version" => version}, %{token: "k"}) ==
                 {:error, "unsupported_version"}
      end
    end
  end

  test "missing versions remain invalid requests" do
    for body <- [%{}, %{"x" => 1}] do
      assert Ziggy.handle_request("ziggy.identity", body, %{token: "k"}) ==
               {:error, "invalid_request"}
    end
  end
end
