defmodule Ziggy.ControlResponseTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  setup do
    control =
      start_supervised!(
        {OverallsProtocol.Control.Client,
         [
           url: "https://127.0.0.1:1",
           service: "ziggy",
           credential: fn -> {:error, :fixture_unavailable} end,
           bind: fn -> %{} end
         ]}
      )

    %{control: control}
  end

  # @cc [owner:ghuntley,label:verification;recovery] ziggy-socket-result-classes
  # Only an exact completion conflict on complete is a durable conflict;
  # unauthorized and version refusal keep their classes, and every other
  # answer or transport failure is an authority outage while the owner has
  # no terminal version refusal. Pending stopped-owner refusal has its own
  # actual-TLS property.
  property(
    "only an exact completion conflict is classified as a durable conflict",
    %{control: control},
    profile: :ci,
  ) do
    check all(
            route <- member_of(["complete", "admit", "renew", "agent_result"]),
            answer <-
              member_of([
                {:error, "completion_conflict"},
                {:error, "duplicate_request"},
                {:error, "invalid_request"},
                {:error, "unauthorized"},
                {:error, "unsupported_version"},
                {:error, "unavailable"},
                {:error, :timeout},
                {:error, :busy},
                {:error, :unproven}
              ]),
            max_runs: 100
          ) do
      expected =
        case answer do
          {:error, "unauthorized"} ->
            {:error, :unauthorized}

          {:error, "unsupported_version"} ->
            {:error, :unsupported_version}

          {:error, "completion_conflict"} when route == "complete" ->
            {:error, :completion_conflict}

          _ ->
            {:error, :authority_unavailable}
        end

      assert Ziggy.Control.socket_result(answer, route, 16_384, control) == expected
    end
  end

  test "documents are bounded and only maps become acknowledgements" do
    assert {:ok, %{"acknowledged" => "synthetic-request"}} =
             Ziggy.Control.socket_result(
               {:ok, %{"acknowledged" => "synthetic-request"}},
               "complete",
               16_384,
               nil
             )

    oversized = %{"padding" => String.duplicate("x", 16_384)}

    assert Ziggy.Control.socket_result({:ok, oversized}, "complete", 16_384, nil) ==
             {:error, :authority_unavailable}

    for answer <- [{:ok, []}, {:ok, nil}, {:error, "duplicate_request"}] do
      assert {:error, :authority_unavailable} =
               Ziggy.Control.socket_result(answer, "complete", 16_384, nil)
    end
  end
end
