defmodule MarshallWeb.GitLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User
  alias Marshall.Enrico.{AuditEvent, Repository}
  alias Marshall.Compute.Ledger

  test "signed-in readers can browse only registered GitHub namespaces", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/git")
    user = account(false)

    repo =
      Ledger.create!(Repository, :register, %{
        namespace: "github",
        owner: "nixos",
        name: "nixpkgs",
        registered_by_id: user.id
      })

    {:ok, listing, _} = live(signed_in(conn, user), ~p"/git")
    assert render(listing) =~ "github/nixos/nixpkgs"
    {:ok, viewer, _} = live(signed_in(conn, user), ~p"/git/github/nixos/nixpkgs")
    assert render(viewer) =~ repo.owner
    assert render(viewer) =~ "Mirror contents are unavailable"
    {:ok, absent, _} = live(signed_in(conn, user), ~p"/git/github/other/repo")
    assert render(absent) =~ "Repository unavailable"
  end

  test "admin view exposes redacted mirror audit and rejects invalid source", %{conn: conn} do
    admin = account(true)
    id = Ash.UUID.generate()

    Ledger.create!(AuditEvent, :record, %{
      repository_id: id,
      actor_id: admin.id,
      kind: :registered
    })

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/git")
    assert render(view) =~ "Recent mirror audit"
    assert render(view) =~ id
    assert render(view) =~ admin.id
    view |> form("form", git: %{owner: "-invalid", repo: "repo"}) |> render_submit()
    assert render(view) =~ "Could not register repository"
    assert Ledger.read!(Repository) == []
  end

  test "recently elevated admin registers a canonical mirror and records intent", %{conn: conn} do
    admin = account(true)
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/git")

    view |> form("form", git: %{owner: "NixOS", repo: "nixpkgs"}) |> render_submit()

    assert render(view) =~ "github/nixos/nixpkgs"
    assert [%{owner: "nixos", name: "nixpkgs"} = repo] = Ledger.read!(Repository)

    assert Enum.map(Ledger.read!(AuditEvent, repository_id: repo.id), & &1.kind) |> Enum.sort() ==
             [:refresh_requested, :registered]

    render_click(view, "refresh", %{"id" => repo.id})

    assert Enum.count(
             Ledger.read!(AuditEvent, repository_id: repo.id),
             &(&1.kind == :refresh_requested)
           ) ==
             2

    Ledger.update!(repo, :begin_refresh, %{
      attempt_id: Ash.UUID.generate(),
      last_attempt_at: DateTime.utc_now()
    })

    render_click(view, "refresh", %{"id" => repo.id})
    assert render(view) =~ "Refresh already in progress."

    assert Enum.count(
             Ledger.read!(AuditEvent, repository_id: repo.id),
             &(&1.kind == :refresh_requested)
           ) == 2

    render_click(view, "remove", %{"id" => repo.id})
    assert [%{phase: :removing}] = Ledger.read!(Repository, id: repo.id)

    assert Enum.any?(
             Ledger.read!(AuditEvent, repository_id: repo.id),
             &(&1.kind == :remove_requested)
           )

    jobs =
      Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Marshall.Enrico.Worker)
      |> Enum.filter(&(&1.args["id"] == repo.id))

    assert Enum.any?(jobs, &(&1.args["op"] == "refresh"))
    assert Enum.any?(jobs, &(&1.args["op"] == "remove"))
  end

  defp account(admin),
    do:
      Ash.Seed.seed!(
        User,
        %{email: "#{Ash.UUID.generate()}@example.test", administrator: admin}
      )

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
