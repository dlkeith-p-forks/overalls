defmodule MarshallWeb.MachinePinsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.{Access, Compute}
  alias Marshall.Access.Pin
  alias Marshall.Compute.{Ledger, Operation, VirtualMachine}

  setup do
    for _ <- 1..2, do: host_fixture()
    owner = user()

    vms =
      for _ <- 1..3 do
        {:ok, vm} = Compute.provision(request(), actor: owner)
        vm
      end

    %{owner: owner, vms: Enum.sort_by(vms, & &1.id)}
  end

  # @cc [owner:ghuntley,label:product;verification] machines-list-pin-order
  # Toggling a pin on the list MUST re-render the pinned machine before every
  # unpinned row with its Pinned label, keep each machine exactly once and
  # restore the id order when the pin is removed.
  test "pinning from the machines list moves the machine to the top", %{
    conn: conn,
    owner: owner,
    vms: [first, second, third]
  } do
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines")
    assert row_ids(view) == [first.id, second.id, third.id]
    assert has_element?(view, "#pin-#{third.id}[aria-pressed=false]", "Pin")

    view |> element("#pin-#{third.id}") |> render_click()
    assert row_ids(view) == [third.id, first.id, second.id]

    assert has_element?(
             view,
             "#machines tr[data-pinned=true] td[data-label=Status] #machine-pinned-#{third.id}",
             "Pinned"
           )

    assert has_element?(view, "#machine-pinned-#{third.id} + .status-label[data-state]")

    assert has_element?(view, "#pin-#{third.id}[aria-pressed=true]", "Unpin")
    refute has_element?(view, "#machine-pinned-#{first.id}")
    assert [%Pin{state: :pinned}] = Ledger.read!(Pin, vm_id: third.id, user_id: owner.id)

    view |> element("#pin-#{second.id}") |> render_click()
    assert row_ids(view) == [second.id, third.id, first.id]

    # A refresh keeps the order and does not duplicate the pinned rows.
    send(view.pid, :refresh)
    assert row_ids(view) == [second.id, third.id, first.id]

    view |> element("#pin-#{third.id}") |> render_click()
    assert row_ids(view) == [second.id, first.id, third.id]
    assert has_element?(view, "#pin-#{third.id}[aria-pressed=false]", "Pin")
  end

  test "the overview shows pinned machines first with their own toggle", %{
    conn: conn,
    owner: owner,
    vms: [first, _second, third]
  } do
    {:ok, view, _} = live(signed_in(conn, owner), "/overview")
    assert hd(preview_ids(view)) == first.id

    view |> element("#pin-#{third.id}") |> render_click()
    assert hd(preview_ids(view)) == third.id
    assert has_element?(view, "#overview-machine-#{third.id}[data-pinned=true]")
    assert has_element?(view, "#overview-machine-pinned-#{third.id}", "Pinned")
    assert length(preview_ids(view)) == 3
    assert length(Enum.uniq(preview_ids(view))) == 3

    view |> element("#pin-#{third.id}") |> render_click()
    assert hd(preview_ids(view)) == first.id
    refute has_element?(view, "#overview-machine-pinned-#{third.id}")
  end

  # @cc [owner:ghuntley,label:product;security] machine-header-pin-delete-fence
  # The header toggle MUST use the shared workspace hook on every tab. While the
  # owner holds the pin, the settings Delete control MUST be disabled with the
  # "Unpin to delete" explanation, and a forged delete event MUST still be
  # refused by the domain with the fixed flash; unpinning restores deletion.
  test "the header toggle fences Delete until the owner unpins", %{
    conn: conn,
    owner: owner,
    vms: [vm | _]
  } do
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/machines/#{vm.id}/settings")
    assert has_element?(view, "#delete-machine:not([disabled])")
    refute has_element?(view, "#delete-pinned")

    view |> element("#pin-#{vm.id}") |> render_click()
    assert has_element?(view, "#machine-pinned", "Pinned")
    assert has_element?(view, "#machine-pinned + #machine-os + #machine-state")
    assert has_element?(view, "#pin-#{vm.id}[aria-pressed=true]", "Unpin")
    assert has_element?(view, "#delete-machine[disabled]")
    assert has_element?(view, "#delete-pinned", "Unpin to delete")

    html = render_click(view, "lifecycle", %{"kind" => "delete", "key" => Ash.UUID.generate()})
    assert html =~ "Unpin this machine before deleting it."
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert [] = Enum.filter(Ledger.read!(Operation, vm_id: vm.id), &(&1.kind == :delete))

    # The terminal tab shares the hook, so the toggle works there too.
    {:ok, terminal, _} = live(conn, ~p"/machines/#{vm.id}")
    assert has_element?(terminal, "#pin-#{vm.id}[aria-pressed=true]")
    terminal |> element("#pin-#{vm.id}") |> render_click()
    assert has_element?(terminal, "#pin-#{vm.id}[aria-pressed=false]", "Pin")
    assert [%Pin{state: :unpinned}] = Ledger.read!(Pin, vm_id: vm.id, user_id: owner.id)

    send(view.pid, :refresh)
    assert has_element?(view, "#delete-machine:not([disabled])")
    view |> element("#delete-machine") |> render_click()
    assert [%{desired_state: :deleted}] = Ledger.read!(VirtualMachine, id: vm.id)
    refute has_element?(view, "#pin-#{vm.id}")
  end

  test "a shared viewer's pin never disables the owner's Delete and refusals show a flash", %{
    conn: conn,
    owner: owner,
    vms: [vm | _]
  } do
    member = user()

    {:ok, _} =
      Access.set_access(
        %{
          vm_id: vm.id,
          email: to_string(member.email),
          role: :manager,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    {:ok, member_view, _} = live(signed_in(conn, member), ~p"/machines/#{vm.id}/settings")
    member_view |> element("#pin-#{vm.id}") |> render_click()
    assert has_element?(member_view, "#delete-machine:not([disabled])")

    {:ok, owner_view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    assert has_element?(owner_view, "#delete-machine:not([disabled])")
    refute has_element?(owner_view, "#machine-pinned")

    # The owner pins; the manager's Delete stays enabled but the domain refuses.
    owner_view |> element("#pin-#{vm.id}") |> render_click()
    send(member_view.pid, :refresh)
    assert has_element?(member_view, "#delete-machine:not([disabled])")

    html =
      render_click(member_view, "lifecycle", %{"kind" => "delete", "key" => Ash.UUID.generate()})

    assert html =~ "Unpin this machine before deleting it."
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: vm.id)
  end

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @spec row_ids(Phoenix.LiveViewTest.View.t()) :: [String.t()]
  defp row_ids(view) do
    # Table rows need their table context; a bare tbody fragment drops them.
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#machines tr.machine-row")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "machines-", ""))
  end

  @spec preview_ids(Phoenix.LiveViewTest.View.t()) :: [String.t()]
  defp preview_ids(view) do
    view
    |> element("#overview-machine-preview")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("article")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "overview-machine-", ""))
  end
end
