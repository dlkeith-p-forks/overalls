defmodule OverallsProtocol.EditorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OverallsProtocol.{
    EditorConnect,
    EditorLogin,
    EditorName,
    EditorStream,
    ImageManifest,
    IngressConnect
  }

  @vm "00000000-0000-4000-8000-000000000001"
  @account "00000000-0000-4000-8000-000000000002"
  @host "00000000-0000-4000-8000-000000000003"

  property "origins retain complete independent identities and reject noncanonical spellings" do
    check all(vm <- binary(length: 16), account <- binary(length: 16)) do
      vm_id = uuid(vm)
      guest_account_id = uuid(account)
      label = EditorName.label(vm_id, guest_account_id)
      assert byte_size(label) == 55

      assert {:ok, %{vm_id: ^vm_id, guest_account_id: ^guest_account_id}} =
               EditorName.parse(label)

      refute EditorName.valid_label?(String.upcase(label))
      refute EditorName.valid_label?(label <> "=")
      refute EditorName.valid_label?(label <> ".example.test")
      if vm != account, do: refute(label == EditorName.label(guest_account_id, vm_id))
    end
  end

  property "unknown or missing principal and release fields never become connector authority" do
    check all(field <- member_of(Map.keys(editor_binding())), epoch <- integer(1..100_000)) do
      value = %{editor_binding() | execution_epoch: epoch}
      assert {:ok, encoded} = EditorConnect.encode(value)
      assert {:ok, ^value} = EditorConnect.decode(encoded)
      assert {:ok, ^value} = IngressConnect.decode(encoded)
      refute EditorConnect.valid?(Map.delete(value, field))
      refute EditorConnect.valid?(Map.put(value, :address, "127.0.0.1"))
      assert {:error, :invalid_connector_request} = IngressConnect.encode(%{value | port: 22})
    end
  end

  property "renewal cannot change account, execution, package or origin" do
    check all(
            ttl <- integer(1..30_000),
            field <- member_of([:uid, :username, :generation, :editor_release, :editor_origin])
          ) do
      previous = %{binding: editor_binding(), user_id: @account}
      wire = JSON.decode!(JSON.encode!(editor_binding()))

      response = %{
        "version" => 1,
        "grant" => %{"binding" => wire, "ttl" => ttl, "user_id" => @account}
      }

      assert {:ok, _} =
               EditorStream.response(
                 "editor-renew",
                 response,
                 @host,
                 editor_binding().label,
                 previous
               )

      changed =
        case field do
          :uid -> 200_001
          :username -> "another"
          :generation -> 2
          :editor_release -> String.duplicate("c", 64)
          :editor_origin -> "https://" <> editor_binding().label <> ".foreign.test"
        end

      changed_response = put_in(response, ["grant", "binding", Atom.to_string(field)], changed)

      assert {:error, :invalid_message} =
               EditorStream.response(
                 "editor-renew",
                 changed_response,
                 @host,
                 editor_binding().label,
                 previous
               )
    end
  end

  test "token purposes are separate and caller approval authority is refused" do
    state = Base.url_encode64(<<0::256>>, padding: false)
    cookie = "audi_editor_cookie_" <> state
    assert EditorLogin.token?(cookie, :cookie)
    refute EditorLogin.token?(cookie, :code)
    refute OverallsProtocol.WebLogin.token?(cookie, :cookie)

    value = %{
      "version" => 1,
      "label" => editor_binding().label,
      "state_digest" => String.duplicate("a", 64)
    }

    assert {:ok, :begin_editor_login, _} = EditorLogin.request("editor-login-begin", value)

    assert {:error, :invalid_request} =
             EditorLogin.request("editor-login-begin", Map.put(value, "user_id", @account))

    assert {:error, :invalid_request} =
             EditorLogin.request("editor-login-begin", %{value | "version" => 2})
  end

  test "origin and webview encodings are distinct, bounded and release-specific" do
    label = editor_binding().label

    for origin <- [
          "http://#{label}.apps.test",
          "https://#{label}.apps.test/",
          "https://#{label}.apps.test?x=1",
          "https://user@#{label}.apps.test",
          "https://#{label}.apps.test:443",
          "https://foreign.apps.test",
          "https://#{label}.Apps.test",
          "https://#{label}.apps.test:invalid",
          "https://[invalid"
        ] do
      refute EditorConnect.origin?(origin, label)
    end

    assert EditorConnect.origin?("https://#{label}.apps.test:8443", label)
    assert EditorName.webview_label?("1" <> String.duplicate("v", 51))
    refute EditorName.webview_label?("2" <> String.duplicate("v", 51))

    assert EditorConnect.webview_template(editor_binding()) ==
             "https://{{uuid}}.apps.test/code-assets/#{editor_binding().editor_release}/out/vs/workbench/contrib/webview/browser/pre/"
  end

  test "asset acknowledgements are closed and match the exact release" do
    descriptor = %{
      protocol: 1,
      commit: String.duplicate("a", 40),
      release: String.duplicate("b", 64)
    }

    ready = %{
      "editor_protocol" => 1,
      "editor_commit" => descriptor.commit,
      "editor_release" => descriptor.release
    }

    assert {:ok, _} =
             OverallsProtocol.EditorAssets.response(
               %{"version" => 1, "ready" => ready},
               descriptor
             )

    for invalid <- [
          nil,
          "invalid",
          %{},
          Map.put(ready, "extra", true),
          Map.put(ready, "version", 2),
          Map.put(ready, "editor_release", String.duplicate("c", 64))
        ] do
      assert {:error, :invalid_message} =
               OverallsProtocol.EditorAssets.response(
                 %{"version" => 1, "ready" => invalid},
                 descriptor
               )
    end

    assert EditorConnect.valid?(%{editor_binding() | username: "alice.smith"})
  end

  test "editor release participates in immutable image identity and is never inferred" do
    artifact = %{"bytes" => 1024, "sha256" => String.duplicate("a", 64)}

    manifest = %{
      "version" => 4,
      "workspace_source_version" => 2,
      "architecture" => "x86_64",
      "boot_args" => "console=ttyS0",
      "minimum_memory_bytes" => 2_147_483_648,
      "minimum_disk_bytes" => 8_589_934_592,
      "kernel" => artifact,
      "initrd" => artifact,
      "rootfs" => artifact,
      "editor" => %{
        "protocol" => 1,
        "commit" => editor_binding().editor_commit,
        "release" => editor_binding().editor_release
      }
    }

    assert {:ok, image} = ImageManifest.validate(manifest)

    assert {:ok, changed} =
             manifest
             |> put_in(["editor", "release"], String.duplicate("d", 64))
             |> ImageManifest.validate()

    refute image.id == changed.id
    assert {:ok, _} = ImageManifest.editor(manifest)

    assert {:error, :editor_unavailable} =
             manifest |> Map.delete("editor") |> ImageManifest.editor()

    assert {:ok, without_editor} = ImageManifest.validate(Map.delete(manifest, "editor"))
    refute without_editor.id == image.id

    for malformed <- [nil, %{}, Map.put(manifest["editor"], "unknown", true)] do
      assert {:error, :invalid_image_manifest} =
               ImageManifest.validate(Map.put(manifest, "editor", malformed))
    end
  end

  @spec editor_binding() :: EditorConnect.binding()
  defp editor_binding do
    label = EditorName.label(@vm, @account)

    %{
      vm_id: @vm,
      host_id: @host,
      placement_id: @vm,
      session_id: @host,
      execution_epoch: 1,
      generation: 1,
      label: label,
      service: :editor,
      port: 4444,
      user_id: @account,
      guest_account_id: @account,
      uid: 200_000,
      username: "alice",
      editor_protocol: 1,
      editor_commit: String.duplicate("a", 40),
      editor_release: String.duplicate("b", 64),
      editor_origin: "https://#{label}.apps.test"
    }
  end

  @spec uuid(binary()) :: String.t()
  defp uuid(bytes) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = Base.encode16(bytes, case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end
end
