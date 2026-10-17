defmodule MarshallWeb.AdminLillyNodesLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Compute.{Ledger, Host}

  test "ordinary users can inspect maintenance; admin requests and pauses a campaign", %{
    conn: conn
  } do
    source = host_fixture()

    assert {:ok, _, _} = live(signed_in(conn, user()), ~p"/admin/nodes")

    admin = Ledger.update!(user(), :assign_administrator, %{administrator: true})
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/nodes/#{source.host.id}")
    assert has_element?(view, "#start-evacuation")
    assert has_element?(view, "#terminal-stream-health", "Local stream: unavailable")
    view |> element("#preview-evacuation") |> render_click()
    assert has_element?(view, "#evacuation-preview-note", "Advisory")
    view |> element("#capacity-details") |> render_click()
    assert has_element?(view, "#admission-overhead")

    view
    |> form("#admission-settings", %{
      "enabled" => "true",
      "overhead_cores" => "2",
      "overhead_memory_bytes" => "2147483648"
    })
    |> render_submit()

    [configured] = Ledger.read!(Host, id: source.host.id)
    assert configured.overhead_cores == 2
    assert configured.overhead_memory_bytes == 2_147_483_648

    assert [%{kind: :host_configure}] =
             Ledger.read!(Marshall.Accounts.AdminEvent, target_id: configured.id)

    view |> element("#start-evacuation") |> render_click()
    assert has_element?(view, "#evacuation-timeline", "Campaign requested")
    assert has_element?(view, "#evacuation-campaign", "Active")
    [host] = Ledger.read!(Host, id: source.host.id)
    assert host.enabled and host.maintenance_mode == :evacuating
    view |> element("#pause-evacuation") |> render_click()
    assert has_element?(view, "#evacuation-campaign", "Paused")
    Ledger.update!(admin, :assign_administrator, %{administrator: false})
    view |> element("#continue-evacuation") |> render_click()
    assert render(view) =~ "Administrative changes require an administrator"
  end

  test "node list renders enrolled compute hosts without transfer metadata", %{conn: conn} do
    source = host_fixture()
    admin = Ledger.update!(user(), :assign_administrator, %{administrator: true})
    {:ok, view, html} = live(signed_in(conn, admin), ~p"/admin/nodes")
    assert has_element?(view, "#lilly-node-rows", source.host.name)
    refute html =~ "ssh-ed25519"
    refute html =~ "lilly.example.test"
  end

  test "workload preview and approval controls render real campaign data", %{conn: conn} do
    source = host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    Ledger.update!(vm, :observe, %{observed_state: :running})
    destination = host_fixture()
    admin = Ledger.update!(user(), :assign_administrator, %{administrator: true})
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/nodes/#{source.host.id}")
    view |> element("#preview-evacuation") |> render_click()
    assert has_element?(view, "#evacuation-workloads", destination.host.name)
    view |> element("#start-evacuation") |> render_click()
    [item] = Ledger.read!(Marshall.Compute.EvacuationItem, vm_id: vm.id)
    view |> element("#approve-#{item.id}") |> render_click()
    assert has_element?(view, "#evacuation-workloads", "Downtime approved")
    view |> element("#replan-#{item.id}") |> render_click()
    assert has_element?(view, "#approve-#{item.id}")
    # Re-planning clears consent; a running guest cannot move without it (ADR-0155).
    assert {:ok, :blocked} = Marshall.Compute.Evacuations.advance(item.evacuation_id)
    [replanned] = Ledger.read!(Marshall.Compute.EvacuationItem, vm_id: vm.id)
    view |> element("#approve-#{replanned.id}") |> render_click()
    assert {:ok, :scheduled} = Marshall.Compute.Evacuations.advance(item.evacuation_id)
    send(view.pid, :refresh)
    assert has_element?(view, "#evacuation-workloads", "Phase:")
    refute has_element?(view, "#replan-#{item.id}")
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
