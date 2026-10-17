defmodule Galileo.ControlVersionTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  # @cc [owner:ghuntley,label:verification;recovery] galileo-version-refusal-class
  # A refused control upgrade with HTTP 426 MUST keep the permanent
  # unsupported_version class for every route, whatever the response body; a
  # 401 credential refusal stays unauthorized (ADR-0080); anything else is an
  # authority outage, never a version refusal.
  property "version refusals keep their permanent class on every route" do
    check all(
            status <- member_of([426, 401, 503]),
            routes <-
              list_of(member_of(["authorize", "identity", "renew"]), min_length: 1, max_length: 3),
            max_runs: 6
          ) do
      control = Galileo.ControlStub.start({:refuse, status})
      assert_receive {:control_path, "/api/control/v1"}, 1_000

      expected =
        case status do
          426 -> {:error, :unsupported_version}
          401 -> {:error, :unauthorized}
          _ -> {:error, :authority_unavailable}
        end

      for route <- routes do
        assert Galileo.Control.request(control, route, %{}) == expected
      end

      refute_receive {:control_request, _}, 50
    end
  end

  test "requests travel as galileo ops and map domain refusals" do
    responder = fn
      "galileo.identity", %{} -> {:ok, %{"host_id" => "01234567-89ab-4def-8123-456789abcdef"}}
      "galileo.renew", _body -> {:error, "unauthorized"}
      "galileo.authorize", _body -> {:error, "invalid_request"}
    end

    control = Galileo.ControlStub.start(responder)

    assert {:ok, %{"host_id" => "01234567-89ab-4def-8123-456789abcdef"}} =
             Galileo.Control.request(control, "identity", %{})

    assert_receive {:control_request, "galileo.identity"}
    assert Galileo.Control.request(control, "renew", %{}) == {:error, :unauthorized}
    assert Galileo.Control.request(control, "authorize", %{}) == {:error, :authority_unavailable}
  end
end
