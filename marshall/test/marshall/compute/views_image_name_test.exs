defmodule Marshall.Compute.ViewsImageNameTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Marshall.Compute
  alias MarshallWeb.WorkspaceComponents

  setup do
    Map.put(host_fixture(), :user, user())
  end

  test "authorized views project the registered image display name only", %{user: user} = c do
    ubuntu = ubuntu_image_fixture(c)
    {:ok, vm} = Compute.provision(request(%{image_id: ubuntu.id}), actor: user)

    assert {:ok, view} = Compute.get_vm(%{vm_id: vm.id}, actor: user)
    assert view.image_name == "Ubuntu 26.04 LTS"
    assert view.image_id == ubuntu.id
    refute Map.has_key?(view, :manifest)
    refute Map.has_key?(view, :image)

    assert {:ok, %{items: [listed]}} = Compute.list_vms(%{limit: 10}, actor: user)
    assert listed.image_name == "Ubuntu 26.04 LTS"

    assert {:ok, resolved} = Compute.resolve_vm(%{reference: vm.name}, actor: user)
    assert resolved.image_name == "Ubuntu 26.04 LTS"
  end

  test "the default image projects its own registered name", %{user: user} do
    {:ok, vm} = Compute.provision(request(), actor: user)
    assert {:ok, view} = Compute.get_vm(%{vm_id: vm.id}, actor: user)
    assert view.image_name == "synthetic-test-image"
  end

  test "the operating-system label renders text for a name and nothing without one" do
    rendered =
      render_component(&WorkspaceComponents.os_label/1, vm: %{image_name: "NixOS"}, id: "os")

    assert rendered =~ ~s(id="os")
    assert rendered =~ ~s(data-tone="muted")
    assert rendered =~ ">NixOS<"

    for vm <- [%{image_name: nil}, %{image_name: ""}, %{}] do
      assert String.trim(render_component(&WorkspaceComponents.os_label/1, vm: vm, id: "os")) ==
               ""

      assert WorkspaceComponents.operating_system(vm) == nil
    end
  end
end
