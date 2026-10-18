defmodule MarshallWeb.CloneComponentsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest
  alias MarshallWeb.CloneComponents

  @phases [
    :queued,
    :preparing,
    :stopping,
    :capturing,
    :copying,
    :publishing,
    :cleaning,
    :complete,
    :cancelling,
    :cancelled,
    :failed
  ]

  test "every persisted state has a readable status and no invented success for interruptions" do
    assert Ash.Resource.Info.attribute(Marshall.Compute.CloneRequest, :phase).constraints[:one_of] ==
             @phases

    labels = [
      "Queued",
      "Preparing clone",
      "Stopping source for snapshot",
      "Taking snapshot",
      "Copying files",
      "Creating cloned machine",
      "Finishing up",
      "Clone complete",
      "Cancelling clone",
      "Clone cancelled",
      "Clone needs attention"
    ]

    for {phase, label} <- Enum.zip(@phases, labels) do
      progress = CloneComponents.presentation(request(%{phase: phase}))
      assert progress.label == label
      assert progress.detail != ""
      assert progress.source != ""

      if phase in [:failed, :cancelled, :cancelling] do
        assert progress.steps == []
      else
        assert length(progress.steps) == 5

        assert Enum.count(progress.steps, fn {_, state} -> state == :current end) ==
                 if(phase == :complete, do: 0, else: 1)
      end
    end
  end

  test "source recovery can finish during copying and does not complete the clone" do
    copying = request(%{phase: :copying, active: true, original_power_state: :running})

    assert CloneComponents.presentation(copying).source ==
             "Waiting for source recovery confirmation."

    restored = CloneComponents.presentation(%{copying | source_restored_at: DateTime.utc_now()})
    assert restored.label == "Copying files"
    assert restored.source == "Source returned to its original power state."
    assert List.last(restored.steps) == {"Finishing", :pending}
    refute restored.open?

    stopped =
      CloneComponents.presentation(%{
        copying
        | original_power_state: :stopped,
          source_restored_at: DateTime.utc_now()
      })

    assert stopped.source ==
             "Source was kept stopped, matching its state when this request began."
  end

  test "publication exposes navigation during cleanup without claiming completion" do
    clone = request(%{phase: :cleaning, active: true, published_at: DateTime.utc_now()})
    html = render_component(&CloneComponents.card/1, id: "clone-test", clone: clone)
    assert html =~ "Finishing up"
    refute html =~ "Clone complete"
    assert html =~ ~s(href="/machines/#{clone.destination_vm_id}")
    refute html =~ ~s(phx-click="clone-cancel")
    assert html =~ ~s(aria-current="step")
    assert html =~ "Waiting for source recovery confirmation."
  end

  test "failed source restart stays distinct from copy progress and can be retried after publication" do
    clone =
      request(%{
        phase: :cleaning,
        active: true,
        published_at: DateTime.utc_now(),
        failure: "source_restart_failed"
      })

    progress = CloneComponents.presentation(clone)
    assert progress.label == "Needs attention"
    assert progress.source == "Source recovery needs attention."
    assert progress.retry?
    assert progress.open?
    refute progress.cancel?
    html = render_component(&CloneComponents.card/1, id: "clone-test", clone: clone)
    assert html =~ "The source could not restart."
    assert html =~ ~s(phx-click="clone-retry")
    assert html =~ ~s(phx-disable-with="Requesting retry…")
    refute html =~ "source_restart_failed"
  end

  test "terminal destination failure uses ordinary machine controls" do
    progress =
      CloneComponents.presentation(
        request(%{
          phase: :failed,
          failure: "destination_start_failed",
          published_at: DateTime.utc_now()
        })
      )

    assert progress.open?
    refute progress.retry?
    refute progress.cancel?
    assert progress.failure =~ "Open it to review its status"
  end

  test "queued cancellation does not claim restoration and unknown errors are not exposed" do
    progress = CloneComponents.presentation(request(%{phase: :cancelled, queue_position: nil}))
    assert progress.source == "Cancelled before the snapshot started."
    refute progress.cancel?

    html =
      render_component(&CloneComponents.card/1,
        id: "clone-test",
        clone:
          request(%{
            phase: :failed,
            failure: "unexpected-internal-value",
            name: "<script>bad()</script>"
          })
      )

    assert html =~ "The request encountered a problem."
    refute html =~ "unexpected-internal-value"
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "retry intent is reported as pending recovery instead of another failure" do
    progress =
      CloneComponents.presentation(
        request(%{phase: :copying, active: true, failure: "retry_source_restart"})
      )

    assert progress.label == "Copying files"
    assert progress.source == "Source recovery retry requested."
    assert progress.failure == nil
  end

  property "publication alone gates opening and restoration never changes the copy stages" do
    phase = draw("phase", member_of(@phases))
    published? = draw("published?", boolean())
    restored? = draw("restored?", boolean())
    active? = draw("active?", boolean())
    failure = draw("failure", member_of([nil, "source_restart_failed", "insufficient_capacity"]))
    power = draw("power", member_of([nil, :running, :stopped]))

    clone =
      request(%{
        phase: phase,
        active: active?,
        failure: failure,
        original_power_state: power,
        published_at: if(published?, do: DateTime.utc_now()),
        source_restored_at: if(restored?, do: DateTime.utc_now())
      })

    progress = CloneComponents.presentation(clone)
    assert progress.open? == published?
    assert progress.cancel? == (!published? && phase not in [:complete, :cancelled])
    assert progress.retry? == (!is_nil(failure) && (active? || !published?))

    assert progress.steps ==
             CloneComponents.presentation(%{clone | source_restored_at: nil}).steps
  end

  @spec request(map()) :: CloneComponents.request()
  defp request(overrides) do
    Map.merge(
      %{
        id: "bc4e1741-e3af-46aa-b0fa-d034a55024e2",
        name: "test-copy",
        destination_vm_id: "b5046159-e4e9-42f9-be40-1b69d5a2c659",
        phase: :queued,
        active: false,
        failure: nil,
        original_power_state: nil,
        source_restored_at: nil,
        published_at: nil,
        queue_position: nil
      },
      overrides
    )
  end
end
