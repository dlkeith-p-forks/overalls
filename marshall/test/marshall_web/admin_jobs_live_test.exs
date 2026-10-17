defmodule MarshallWeb.AdminJobsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Marshall.Accounts.User
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  test "job viewing requires a signed-in account", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/jobs")

    assert {:ok, _, _} = live(signed_in(conn, user(false)), ~p"/admin/jobs")
  end

  test "filters select jobs without exposing payloads or exceptions", %{conn: conn} do
    job = job("discarded")
    {:ok, view, html} = live(signed_in(conn, user(false)), ~p"/admin/jobs")
    assert has_element?(view, "#jobs-#{job.id}", "Failed")
    refute html =~ "private-job-value"

    view
    |> form("#job-filters", filters: %{queue: job.queue, state: "completed"})
    |> render_submit()

    assert has_element?(view, "#jobs-empty")
    refute has_element?(view, "#jobs-#{job.id}")

    view
    |> form("#job-filters", filters: %{queue: job.queue, state: "discarded"})
    |> render_submit()

    assert has_element?(view, "#jobs-#{job.id}")
  end

  test "retry uses the displayed job, writes an audit receipt and updates the view", %{conn: conn} do
    admin = user(true)
    job = job("discarded")
    other = job("discarded")
    {:ok, view, html} = live(signed_in(conn, admin), ~p"/admin/jobs/#{job.id}")
    assert has_element?(view, "#retry-job")
    refute html =~ "private-job-value"
    render_click(view, "retry", %{"id" => other.id})
    assert Repo.get!(Oban.Job, job.id).state == "available"
    assert Repo.get!(Oban.Job, other.id).state == "discarded"

    assert [%{resource_id: id}] =
             Ledger.read!(Marshall.Administration.AuditEvent, actor_id: admin.id)

    assert id == to_string(job.id)
    refute has_element?(view, "#retry-job")
    assert has_element?(view, "#job-detail", "Queued")
  end

  test "pruned history stays visible but cannot be retried", %{conn: conn} do
    job = job("discarded")
    Repo.delete_all(from j in Oban.Job, where: j.id == ^job.id)
    {:ok, view, _} = live(signed_in(conn, user(true)), ~p"/admin/jobs/#{job.id}")
    assert has_element?(view, "#job-detail", "Archived history")
    assert has_element?(view, "#job-events", "Failed")
    refute has_element?(view, "#retry-job")
  end

  test "demotion blocks retry and token revocation blocks refresh", %{conn: conn} do
    admin = user(true)
    job = job("discarded")
    session = signed_in(conn, admin)
    {:ok, view, _} = live(session, ~p"/admin/jobs/#{job.id}")
    demoted = Ledger.update!(admin, :assign_administrator, %{administrator: false})
    render_click(view, "retry", %{})
    assert render(view) =~ "Administrative changes require an administrator"
    assert Repo.get!(Oban.Job, job.id).state == "discarded"

    Ledger.update!(demoted, :assign_administrator, %{administrator: true})
    {:ok, view, _} = live(session, ~p"/admin/jobs")

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        get_session(session, "user_token")
      )

    send(view.pid, :refresh)
    assert_redirect(view, ~p"/sign-in")
  end

  defp job(state) do
    job =
      %{"credential" => "private-job-value"}
      |> Oban.Job.new(
        worker: "Marshall.TestWorker",
        queue: "ui_#{System.unique_integer([:positive])}"
      )
      |> Oban.insert!()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: state, attempt: 1, errors: [%{"error" => "private-job-value", "attempt" => 1}]]
    )

    job
  end

  defp user(admin),
    do:
      Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test", administrator: admin})

  defp signed_in(conn, user) do
    user = if user.administrator, do: Marshall.PasskeyFixture.verified_session(user), else: user

    {:ok, token, _} =
      if user.__metadata__[:token],
        do: {:ok, user.__metadata__.token, %{}},
        else: AshAuthentication.Jwt.token_for_user(user)

    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
