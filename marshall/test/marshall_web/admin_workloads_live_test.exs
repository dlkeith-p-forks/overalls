defmodule MarshallWeb.AdminWorkloadsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User

  test "workload inventory is available to signed-in users and exposes no terminal data", %{
    conn: conn
  } do
    ordinary = Ash.Seed.seed!(User, %{email: "workload-#{Ash.UUID.generate()}@example.test"})

    assert {:ok, _, _} = live(signed_in(conn, ordinary), ~p"/admin/workloads")

    admin =
      Ash.Seed.seed!(User, %{
        email: "workload-admin-#{Ash.UUID.generate()}@example.test",
        administrator: true
      })

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/workloads")
    assert has_element?(view, "h1", "Fleet workloads")
    refute render(view) =~ "token_hash"
    refute render(view) =~ "terminal_bytes"
  end

  test "workload presentation localizes states and unplaced hosts without changing state attributes" do
    reader = Marshall.ComputeFixtures.user()
    id = Ash.UUID.generate()

    workload = %{
      id: id,
      name: "reviewed-workload",
      owner_email: reader.email,
      owner_time_zone: nil,
      host_id: nil,
      vcpu: 1,
      memory_bytes: 1_073_741_824,
      observed_state: :pending,
      desired_state: :running
    }

    Gettext.with_locale(MarshallWeb.Gettext, "ja", fn ->
      document =
        render_component(&MarshallWeb.Admin.WorkloadsLive.render/1,
          workloads: [workload],
          current_user: reader,
          flash: %{},
          admin_authorized: false,
          refreshed_at: nil,
          now: DateTime.utc_now(),
          time_zone: "Etc/UTC"
        )
        |> LazyHTML.from_fragment()

      for {selector, source} <- [
            {"#admin-workload-#{id} td:nth-child(2)", "Unplaced"},
            {"#admin-workload-#{id} [data-state=pending]", "Pending"},
            {"#admin-workload-#{id} td:nth-child(4) > .muted", "Running"}
          ] do
        translated = Gettext.dgettext(MarshallWeb.Gettext, "admin_workloads", source)
        refute translated == source
        assert document |> LazyHTML.query(selector) |> LazyHTML.text() =~ translated
      end
    end)
  end

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
