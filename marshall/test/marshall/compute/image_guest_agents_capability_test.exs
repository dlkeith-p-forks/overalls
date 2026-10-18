defmodule Marshall.Compute.ImageGuestAgentsCapabilityTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute.{Image, Images}

  @none %{
    available: false,
    readiness: false,
    trust: false,
    ssh: false,
    terminal: false,
    workspace: false,
    flush: false,
    agents: false,
    editor: false,
    inception: false
  }

  # @cc [owner:ghuntley,label:verification;security] image-guest-agents-identity-property
  # Generated firmware manifests MUST report their declared agent set only with
  # their own content-bound ID; kernel manifests MUST report the Linux agent set;
  # any mismatched ID or malformed manifest MUST fail closed as unavailable, with
  # every capability false.
  @tag :hegel_case_sandbox
  property "guest agent capability is bound to the validated manifest and its exact image ID",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    root_bytes = draw("root_bytes", integer(1..137_438_953_472))
    firmware_bytes = draw("firmware_bytes", integer(1..67_108_864))
    agents = draw("agents", member_of(["none", "windows-v1"]))

    manifest =
      windows_image_manifest()
      |> put_in(["root", "bytes"], root_bytes)
      |> put_in(["boot", "firmware", "bytes"], firmware_bytes)
      |> Map.put("minimum_disk_bytes", root_bytes)
      |> Map.put("guest_agents", agents)

    {:ok, validated} = OverallsProtocol.ImageManifest.validate(manifest)
    {:ok, set} = OverallsProtocol.GuestAgents.parse(agents)
    assert {:ok, ^set} = Image.guest_agents_capability(%{id: validated.id, manifest: manifest})
    capabilities = Image.guest_capabilities(%{id: validated.id, manifest: manifest})
    assert capabilities.available
    assert capabilities.readiness == (set == :windows_v1)
    assert capabilities.trust == (set == :windows_v1)
    assert capabilities.ssh == (set == :windows_v1)
    assert capabilities.terminal == (set == :windows_v1)
    assert capabilities.workspace == (set == :windows_v1)
    assert capabilities.flush == (set == :windows_v1)
    assert capabilities.agents == (set == :windows_v1)
    assert capabilities.readiness == (set == :windows_v1)
    refute capabilities.editor
    refute capabilities.inception

    assert {:error, :unavailable} =
             Image.guest_agents_capability(%{id: image_id(), manifest: manifest})

    assert Image.guest_capabilities(%{id: image_id(), manifest: manifest}) == @none

    assert {:error, :unavailable} =
             Image.guest_agents_capability(%{
               id: validated.id,
               manifest: Map.put(manifest, "name", "Windows")
             })
  end

  test "kernel images carry the Linux agent set and malformed rows fail closed" do
    {:ok, validated} = OverallsProtocol.ImageManifest.validate(image_manifest())
    assert {:ok, :linux} = Image.guest_agents_capability(validated)

    assert Image.guest_capabilities(validated) == %{
             available: true,
             readiness: true,
             trust: true,
             ssh: true,
             terminal: true,
             workspace: true,
             flush: true,
             agents: true,
             editor: true,
             inception: true
           }

    for image <- [nil, %{}, %{id: validated.id, manifest: nil}, %{validated | id: "wrong"}] do
      assert {:error, :unavailable} = Image.guest_agents_capability(image)
      assert Image.guest_capabilities(image) == @none
    end
  end

  test "catalog lookups derive the capabilities from the durable row and refuse unknown IDs" do
    linux = image_fixture()
    windows = windows_image_fixture()
    agents = windows_v1_image_fixture()
    assert windows.id == windows_image_id()
    refute agents.id == windows.id
    assert windows.minimum_memory_bytes == 2_147_483_648
    assert windows.minimum_disk_bytes == 34_359_738_368
    assert Images.guest_capabilities(linux.id).terminal
    assert Images.guest_capabilities(linux.id).inception
    assert Images.guest_capabilities(windows.id) == %{@none | available: true}

    assert %{available: true, ssh: true, terminal: true, agents: true, readiness: true} =
             Images.guest_capabilities(agents.id)

    refute Images.guest_capabilities(agents.id).editor
    refute Images.guest_capabilities(agents.id).inception
    assert Images.guest_capabilities("sha256:" <> String.duplicate("0", 64)) == @none
    assert Images.guest_capabilities(nil) == @none

    # Registration is idempotent on the content identity for firmware images too.
    assert {:ok, same} = Images.register(windows_image_manifest(), "renamed")
    assert same.id == windows.id and same.name == "Windows Server 2025"
  end

  test "the separate Windows editor contract retains Windows platform and exact row authority" do
    manifest =
      windows_image_manifest()
      |> Map.merge(%{
        "version" => 7,
        "os" => "windows",
        "guest_agents" => "windows-editor-v1",
        "editor" => Marshall.EditorFixture.descriptor()
      })

    assert {:ok, image} = Images.register(manifest, "synthetic Windows editor candidate")
    assert {:ok, :windows_editor_v1} = Image.guest_agents_capability(image)
    assert Images.guest_platform(image.id) == :windows
    assert Images.readiness_budget_ms(image.id, :customer) == 600_000
    assert Images.guest_capabilities(image.id).editor
    refute Images.guest_capabilities(image.id).inception
    assert Image.guest_capabilities(%{image | id: image_id()}) == @none

    old = windows_v1_image_fixture()
    assert Images.guest_platform(old.id) == :windows
    refute Images.guest_capabilities(old.id).editor
  end

  # @cc [owner:ghuntley,label:verification;security] native-image-capabilities-fail-closed
  # Unapproved native image identities MUST remain available as catalog records
  # while every guest service capability is false, including when their valid
  # manifests declare kernel provenance and workspace source version 2.
  test "unapproved native FreeBSD and illumos rows with provenance keep guest capabilities disabled" do
    for {os, agents} <- [{"freebsd", "freebsd-v1"}, {"illumos", "illumos-v1"}] do
      image = native_image_fixture(os, agents)
      capabilities = Images.guest_capabilities(image.id)

      assert capabilities == %{@none | available: true}
    end
  end

  # @cc [owner:ghuntley,label:verification;security] reviewed-native-capability-identity
  # Only the complete reviewed native image identity bound to its durable row ID
  # MUST grant the reviewed service capabilities. Changed root, firmware or kernel
  # identities MUST remain all-false; corrupt, retained stock and mismatched rows
  # MUST be unavailable. Editor and Inception MUST remain disabled.
  test "reviewed FreeBSD capabilities require the complete exact row-bound manifest" do
    manifest = OverallsProtocol.NativeAdmission.reviewed_manifest()
    assert {:ok, image} = Images.register(manifest, "reviewed FreeBSD")

    assert Images.guest_capabilities(image.id) == %{
             available: true,
             readiness: true,
             trust: true,
             ssh: true,
             terminal: true,
             workspace: true,
             flush: true,
             agents: true,
             editor: false,
             inception: false
           }

    for path <- [["root", "sha256"], ["boot", "firmware", "sha256"], ["kernel", "sha256"]] do
      changed = put_in(manifest, path, String.duplicate("e", 64))
      assert {:ok, changed_image} = Images.register(changed, "changed native identity")
      refute changed_image.id == image.id
      assert Images.guest_capabilities(changed_image.id) == %{@none | available: true}
    end

    assert Image.guest_capabilities(%{image | id: image_id()}) == @none
    assert Image.guest_capabilities(%{image | manifest: Map.delete(manifest, "kernel")}) == @none
    assert Image.guest_capabilities(%{image | manifest: %{}}) == @none
  end
end
