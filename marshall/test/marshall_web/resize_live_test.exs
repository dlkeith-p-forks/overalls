defmodule MarshallWeb.ResizeLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  test "resize drafts survive validation, polling and reload; access is checked", %{conn: conn} do
    host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(%{disk_bytes: 2_147_487_744}), actor: owner)
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/machines/#{vm.id}/resize")
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(owner)
    owner = Ash.Resource.put_metadata(owner, :token, token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    {:ok, view, _} = live(conn, ~p"/machines/#{vm.id}/resize")
    assert has_element?(view, "#resize-form")
    assert has_element?(view, "#confirmed-resources", "2.000003814697265625 GiB")
    assert has_element?(view, "input[name='resize[disk_gib]'][max='500']")
    assert has_element?(view, "input[name='resize[disk_gib]'][value='2.000003814697265625']")
    view |> form("#resize-form", resize: %{disk_gib: "501"}) |> render_submit()
    assert Marshall.Compute.Resize.active(vm.id) == nil

    view
    |> form("#resize-form", resize: %{vcpu: "3", memory_mib: "1024", disk_gib: "4"})
    |> render_change()

    path = assert_patch(view)
    send(view.pid, :refresh)
    assert has_element?(view, "input[name='resize[vcpu]'][value='3']")
    {:ok, reloaded, _} = live(conn, path)
    assert has_element?(reloaded, "input[name='resize[disk_gib]'][value='4']")
    reloaded |> form("#resize-form") |> render_submit()
    assert has_element?(reloaded, "#resize-form")
    assert has_element?(reloaded, "input[name='resize[vcpu]'][value='3']")
    other = user()
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(other)
    other = Ash.Resource.put_metadata(other, :token, token)

    other_conn =
      build_conn()
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(other)

    {:ok, denied, _} = live(other_conn, ~p"/machines/#{vm.id}/resize")
    assert has_element?(denied, "#resize-unavailable")
    refute has_element?(denied, "#resize-form")
  end

  test "manager sees progress separately from confirmed sizes and revocation removes access", %{
    conn: conn
  } do
    host_fixture()
    owner = user()
    manager = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, Resize}
    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Host, vm.host_id)

        Outcomes.ingest_locked!(vm.host_id, [
          %{
            id: Ash.UUID.generate(),
            vm_id: vm.id,
            placement_id: vm.current_placement_id,
            execution_epoch: 1,
            operation_id: operation.id,
            generation: 1,
            sequence: 1,
            state: :running,
            compute_empty: false,
            disk_present: true,
            cleanup_complete: false,
            reason: :none
          }
        ])
      end)

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

    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(manager)
    manager = Ash.Resource.put_metadata(manager, :token, token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(manager)

    {:ok, view, _} = live(conn, ~p"/machines/#{vm.id}/resize")

    view
    |> form("#resize-form", resize: %{vcpu: "3", memory_mib: "1024", disk_gib: "3"})
    |> render_submit()

    assert has_element?(view, "#resize-progress")
    refute has_element?(view, "#resize-form")
    assert has_element?(view, "#confirmed-resources", "2 CPU")
    assert has_element?(view, "#pending-resources", "3 CPU")

    assert has_element?(
             view,
             "#resize-progress li[data-state=current][aria-current=step]",
             "Stop"
           )

    assert has_element?(view, "#resize-progress li[data-state=pending]", "Resize")
    assert has_element?(view, "#resize-progress li[data-state=pending]", "Restart")
    assert has_element?(view, "#resize-progress li[data-state=pending]", "Confirm")
    refute has_element?(view, "#resize-progress li[data-state=done]")
    refute has_element?(view, "#retry-resize")
    active = Resize.active(vm.id)

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: vm.id,
          email: to_string(manager.email),
          role: :revoked,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    send(view.pid, :refresh)
    assert has_element?(view, "#resize-unavailable")
    refute has_element?(view, "#resize-progress")
    render_hook(view, "retry", %{})
    assert Resize.active(vm.id).operation_id == active.operation_id
  end

  # @cc [owner:ghuntley,label:verification;product] resize-page-cancel-tested
  # The page MUST offer cancellation only while stopping, show the cancelling
  # stages, and return to the form with the unchanged sizes once the machine is
  # running again; a page cancel after sizes apply MUST be refused.
  test "the page cancels a resize before any size applies and returns to the form", %{
    conn: conn
  } do
    host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    accept_outcome(vm, 1, :running)
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(owner)
    owner = Ash.Resource.put_metadata(owner, :token, token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    {:ok, view, _} = live(conn, ~p"/machines/#{vm.id}/resize")

    view
    |> form("#resize-form", resize: %{vcpu: "3", memory_mib: "1024", disk_gib: "3"})
    |> render_submit()

    assert has_element?(view, "#cancel-resize")
    render_click(element(view, "#cancel-resize"))
    assert has_element?(view, "#resize-progress", "Cancelling")
    refute has_element?(view, "#cancel-resize")
    assert has_element?(view, "#resize-progress li[data-state=current]", "Stop")
    assert has_element?(view, "#resize-progress li[data-state=pending]", "Restart unchanged")
    accept_outcome(vm, 2, :stopped)
    send(view.pid, :refresh)
    assert has_element?(view, "#resize-progress li[data-state=current]", "Restart unchanged")
    accept_outcome(vm, 3, :running)
    send(view.pid, :refresh)
    assert has_element?(view, "#resize-form")
    assert has_element?(view, "input[name='resize[vcpu]'][value='2']")
    assert Marshall.Compute.Resize.active(vm.id) == nil

    view
    |> form("#resize-form", resize: %{vcpu: "3", memory_mib: "1024", disk_gib: "3"})
    |> render_submit()

    accept_outcome(vm, 4, :stopped)
    send(view.pid, :refresh)
    refute has_element?(view, "#cancel-resize")
    render_hook(view, "cancel", %{})
    assert Marshall.Compute.Resize.active(vm.id).phase == :resizing
  end

  test "completion prefills confirmed sizes and stale drafts require explicit renewal", %{
    conn: conn
  } do
    host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    accept_outcome(vm, 1, :running)
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(owner)
    owner = Ash.Resource.put_metadata(owner, :token, token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    {:ok, view, _} = live(conn, ~p"/machines/#{vm.id}/resize")

    view
    |> form("#resize-form", resize: %{vcpu: "1", memory_mib: "1024", disk_gib: "3"})
    |> render_submit()

    assert has_element?(view, "#resize-progress")
    request = Marshall.Compute.Resize.active(vm.id)
    accept_outcome(vm, 2, :stopped)
    accept_outcome(vm, 3, :stopped, %{applied_sizes: request.target_sizes})
    accept_outcome(vm, 4, :running)
    send(view.pid, :refresh)
    assert has_element?(view, "#resize-form")
    assert has_element?(view, "input[name='resize[vcpu]'][value='1']")
    assert has_element?(view, "input[name='resize[disk_gib]'][value='3']")
    assert has_element?(view, "input[name='resize[expected_generation]'][value='4']")
    view |> form("#resize-form", resize: %{vcpu: "2"}) |> render_change()

    {:ok, _} =
      Compute.lifecycle(%{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    accept_outcome(vm, 5, :stopped)
    send(view.pid, :refresh)
    assert has_element?(view, "#resize-stale-draft")
    assert has_element?(view, "input[name='resize[expected_generation]'][value='4']")
    view |> element("#refresh-resize-request") |> render_click()
    refute has_element?(view, "#resize-stale-draft")
    assert has_element?(view, "input[name='resize[expected_generation]'][value='5']")
    assert has_element?(view, "input[name='resize[vcpu]'][value='2']")
    assert Marshall.Compute.Resize.active(vm.id) == nil
    view |> form("#resize-form") |> render_submit()
    assert Marshall.Compute.Resize.active(vm.id).original_power_state == :stopped
  end

  defp accept_outcome(vm, sequence, state, extra \\ %{}) do
    alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}
    [current] = Ledger.read!(VirtualMachine, id: vm.id)
    [operation] = Ledger.read!(Operation, vm_id: vm.id, generation: current.generation)

    event =
      Map.merge(
        %{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: vm.current_placement_id,
          execution_epoch: 1,
          operation_id: operation.id,
          generation: current.generation,
          sequence: sequence,
          state: state,
          compute_empty: state == :stopped,
          disk_present: true,
          cleanup_complete: false,
          reason: :none
        },
        extra
      )

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Host, vm.host_id)
               Outcomes.ingest_locked!(vm.host_id, [event])
             end)
  end
end
