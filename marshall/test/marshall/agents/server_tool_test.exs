defmodule Marshall.Agents.ServerToolTest do
  # @cc [owner:ghuntley,label:verification;security] server-tool-end-to-end
  # Thread and artifact tool calls from a real model response MUST be queued
  # with an Oban job, never claimed by the guest executor, executed once per
  # claim with the prompting user's authority, and finish with exactly one
  # dispatch and one finish audit row.
  use MarshallWeb.ConnCase, async: false
  use Oban.Testing, repo: Marshall.Repo

  alias Marshall.Agents.{AuditEvent, ServerToolJob}
  alias Marshall.Compute.Ledger
  alias Marshall.ServerToolFixture, as: Fixture

  @moduletag capture_log: true

  setup do
    %{fixture: Fixture.setup()}
  end

  test "an artifact publish runs once, is never executor-claimed and is audited", %{
    fixture: fixture
  } do
    command =
      Fixture.queue!(
        fixture,
        "artifact",
        %{
          "operation" => "publish",
          "base_version" => 0,
          "title" => "Report",
          "content" => "<h1>v1</h1>"
        },
        fixture.member
      )

    assert command.status == :queued
    assert_enqueued(worker: ServerToolJob, args: %{"command_id" => command.id})
    assert Fixture.executor_claim(fixture) == nil

    finished = Fixture.run!(command)
    assert finished.status == :completed

    assert %{"artifact_id" => artifact_id, "version" => 1, "url" => "/artifacts/" <> _} =
             finished.result

    # A duplicate job after completion is a no-op.
    assert Fixture.run!(command).result == finished.result

    kinds =
      Ledger.read!(AuditEvent, target_id: command.id)
      |> Enum.map(& &1.kind)
      |> Enum.sort()

    assert kinds == Enum.sort([:tool_dispatched, :tool_finished, :artifact_published])

    [artifact] = Ledger.read!(Marshall.Artifacts.Artifact, id: artifact_id)
    assert artifact.owner_id == fixture.member.id
    assert artifact.current_version == 1
  end

  test "a stale base is refused with the current version", %{fixture: fixture} do
    first =
      fixture
      |> Fixture.queue!(
        "artifact",
        %{"operation" => "publish", "base_version" => 0, "content" => "<p>a</p>"},
        fixture.member
      )
      |> Fixture.run!()

    id = first.result["artifact_id"]

    second =
      fixture
      |> Fixture.queue!(
        "artifact",
        %{
          "operation" => "publish",
          "artifact_id" => id,
          "base_version" => 0,
          "content" => "<p>b</p>"
        },
        fixture.member
      )
      |> Fixture.run!()

    assert second.status == :failed
    assert second.result == %{"reason" => "stale_base_version", "current_version" => 1}

    edited =
      fixture
      |> Fixture.queue!(
        "artifact",
        %{
          "operation" => "publish",
          "artifact_id" => id,
          "base_version" => 1,
          "edits" => [%{"old_str" => "a", "new_str" => "c"}]
        },
        fixture.member
      )
      |> Fixture.run!()

    assert edited.status == :completed
    assert edited.result["version"] == 2

    read =
      fixture
      |> Fixture.queue!("artifact", %{"operation" => "read", "artifact_id" => id}, fixture.member)
      |> Fixture.run!()

    assert read.result["content"] == "<p>c</p>"
    assert read.result["current_version"] == 2
  end

  test "another user's artifact is not found through the tool", %{fixture: fixture} do
    owned =
      fixture
      |> Fixture.queue!(
        "artifact",
        %{"operation" => "publish", "base_version" => 0, "content" => "<p>private</p>"},
        fixture.owner
      )
      |> Fixture.run!()

    probe =
      fixture
      |> Fixture.queue!(
        "artifact",
        %{"operation" => "read", "artifact_id" => owned.result["artifact_id"]},
        fixture.member
      )
      |> Fixture.run!()

    assert probe.status == :failed
    assert probe.result == %{"reason" => "not_found"}
  end

  test "thread search returns only Cedar-visible threads", %{fixture: fixture} do
    visible = user_thread!(fixture.member, "Visible plan")
    hidden = user_thread!(fixture.owner, "Hidden plan")

    result =
      fixture
      |> Fixture.queue!("thread", %{"operation" => "search"}, fixture.member)
      |> Fixture.run!()

    assert result.status == :completed
    ids = Enum.map(result.result["items"], & &1["id"])
    assert visible.id in ids
    refute hidden.id in ids
  end

  test "revoked machine access cancels the command before it runs", %{fixture: fixture} do
    command =
      Fixture.queue!(fixture, "thread", %{"operation" => "search"}, fixture.member)

    {:ok, _} = Marshall.AgentRevocationFixture.share(fixture, :revoked)
    finished = Fixture.run!(command)
    assert finished.status in [:cancelled, :failed]
  end

  @spec user_thread!(Marshall.Accounts.User.t(), String.t()) :: Marshall.Threads.Thread.t()
  defp user_thread!(user, objective) do
    request = Marshall.ComputeFixtures.request()

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: objective,
          mode: :medium,
          machine_spec: Map.put(request, :team_id, nil),
          idempotency_key: request.idempotency_key
        },
        actor: user
      )

    thread
  end
end
