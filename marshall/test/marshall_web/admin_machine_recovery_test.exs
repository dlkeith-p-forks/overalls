defmodule MarshallWeb.AdminMachineRecoveryTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.{Security, User, Verification}
  alias Marshall.Compute
  alias Marshall.Compute.Ledger
  alias Marshall.PasskeyFixture, as: Fixture

  test "expired administrative terminal access returns to workloads with a recovery explanation",
       %{conn: conn} do
    host_fixture()
    {:ok, vm} = Compute.provision(request(), actor: user())
    actor = Fixture.elevate(Fixture.user(true))
    conn = signed_in(conn, actor)
    {:ok, view, _} = live(conn, "/machines/#{vm.id}/terminals")
    expire(actor)
    send(view.pid, :refresh_terminals)
    flash = assert_redirect(view, "/admin/workloads")
    assert flash["error"] =~ "Administrative verification expired"
    refute Security.recent?(actor)
  end

  test "expired administrative resize access hides mutation controls and preserves its draft URL",
       %{conn: conn} do
    host_fixture()
    {:ok, vm} = Compute.provision(request(), actor: user())
    actor = Fixture.elevate(Fixture.user(true))
    {:ok, view, _} = live(signed_in(conn, actor), "/machines/#{vm.id}/resize")
    view |> form("#resize-form", resize: %{vcpu: "3", disk_gib: "4"}) |> render_change()
    path = assert_patch(view)
    assert path =~ "vcpu"
    expire(actor)
    send(view.pid, :refresh)
    assert has_element?(view, "#admin-access-recovery[href='/admin/workloads']")
    refute has_element?(view, "#resize-form")
    send(view.pid, :refresh)
    assert has_element?(view, "#admin-access-recovery")
    assert Marshall.Compute.Resize.active(vm.id) == nil
  end

  test "owner and shared manager access survive administrator elevation expiry", %{conn: conn} do
    host_fixture()
    owner = Fixture.elevate(Fixture.user(true))
    manager = Fixture.elevate(Fixture.user(true))
    {:ok, vm} = Compute.provision(request(), actor: owner)

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: vm.id,
          email: to_string(manager.email),
          role: :manager,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    for actor <- [owner, manager] do
      {:ok, resize, _} = live(signed_in(conn, actor), "/machines/#{vm.id}/resize")
      {:ok, terminal, _} = live(signed_in(conn, actor), "/machines/#{vm.id}/terminals")
      expire(actor)
      send(resize.pid, :refresh)
      send(terminal.pid, :refresh_terminals)
      assert has_element?(resize, "#resize-form")
      refute has_element?(resize, "#admin-access-recovery")
      assert has_element?(terminal, "#terminal-workspace")
      refute Security.recent?(actor)
    end
  end

  test "expired machine power override refuses the mutation and returns to workloads", %{
    conn: conn
  } do
    host_fixture()
    {:ok, vm} = Compute.provision(request(), actor: user())
    actor = Fixture.elevate(Fixture.user(true))
    {:ok, view, _} = live(signed_in(conn, actor), "/machines/#{vm.id}/terminals")
    expire(actor)
    render_click(view, "machine-power", %{"kind" => "stop", "key" => Ash.UUID.generate()})
    assert_redirect(view, "/admin/workloads")
    [current] = Ledger.read!(Marshall.Compute.VirtualMachine, id: vm.id)
    assert current.desired_state == :running
    assert current.generation == vm.generation
  end

  test "foreign Customer denial never offers administrator verification as recovery", %{
    conn: conn
  } do
    host_fixture()
    {:ok, vm} = Compute.provision(request(%{profile: :customer}), actor: user())
    actor = Fixture.elevate(Fixture.user(true))
    {:ok, resize, _} = live(signed_in(conn, actor), "/machines/#{vm.id}/resize")
    assert has_element?(resize, "#resize-unavailable")
    refute has_element?(resize, "#admin-access-recovery")
    expire(actor)
    send(resize.pid, :refresh)
    refute has_element?(resize, "#admin-access-recovery")

    assert {:error, {:live_redirect, %{to: "/machines"}}} =
             live(signed_in(conn, actor), "/machines/#{vm.id}/terminals")
  end

  @spec signed_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp signed_in(conn, actor),
    do: conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(actor)

  @spec expire(User.t()) :: Verification.t()
  defp expire(actor) do
    [proof] = Ledger.read!(Verification, id: Security.jti(actor))
    Ledger.update!(proof, :verify, %{elevated_until: Ledger.now()})
  end
end
