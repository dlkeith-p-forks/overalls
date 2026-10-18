ExUnit.start()

defmodule Overalls.NativeImagePromotionTest do
  use ExUnit.Case, async: true

  alias Overalls.NativeImagePromotion, as: Promotion
  alias OverallsProtocol.ImageManifest

  @type fixture :: %{
          root: String.t(),
          output: String.t(),
          approval_path: String.t(),
          approval: %{String.t() => Promotion.json()}
        }

  setup do
    root = Path.join(System.tmp_dir!(), "native-promotion-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for os <- ~w(freebsd illumos) do
    test "promotes the exact reviewed #{os} artifacts with a closed output", %{root: root} do
      fixture = fixture(root, unquote(os))
      assert :ok == Promotion.verify!(fixture.approval_path, fixture.output)
      assert Enum.sort(File.ls!(fixture.output)) == ["disk.raw", "firmware", "manifest.json"]
      manifest = fixture.output |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
      assert {:ok, %{id: id}} = ImageManifest.validate(manifest)
      assert id == fixture.approval["image_id"]
    end
  end

  test "refuses an artifact mutation of the same length before publishing a manifest", %{
    root: root
  } do
    fixture = fixture(root, "freebsd")
    File.write!(Path.join(fixture.output, "disk.raw"), "wrong disk")
    refused!(fixture, "artifact_hash")
  end

  test "refuses truncated firmware and a linked artifact", %{root: root} do
    fixture = fixture(root, "freebsd")
    firmware = Path.join(fixture.output, "firmware")
    original = File.read!(firmware)
    File.write!(firmware, "x")
    refused!(fixture, "artifact_size")
    File.write!(Path.join(root, "actual-firmware"), original)
    File.rm!(firmware)
    File.ln_s!(Path.join(root, "actual-firmware"), firmware)
    refused!(fixture, "artifact_file")
  end

  test "refuses a different image identity, extra approval keys and absent scenarios", %{
    root: root
  } do
    fixture = fixture(root, "freebsd")

    for change <- [
          &Map.put(&1, "image_id", "sha256:" <> String.duplicate("0", 64)),
          &Map.put(&1, "admit_without_evidence", true),
          &Map.put(&1, "scenarios", [])
        ] do
      write_json(fixture.approval_path, change.(fixture.approval))
      refused!(fixture)
    end
  end

  test "refuses duplicated scenarios and missing supplemental evidence", %{root: root} do
    fixture = fixture(root, "freebsd")
    [first | rest] = fixture.approval["scenarios"]

    write_json(
      fixture.approval_path,
      Map.put(fixture.approval, "scenarios", [first, first | tl(rest)])
    )

    refused!(fixture, "scenario_set")

    scenarios =
      Enum.map(fixture.approval["scenarios"], fn scenario ->
        if scenario["name"] == "growth", do: Map.put(scenario, "supporting", []), else: scenario
      end)

    write_json(fixture.approval_path, Map.put(fixture.approval, "scenarios", scenarios))
    refused!(fixture, "supporting_count")
  end

  test "refuses foreign disk, kernel, firmware, VMM, OS and claimed admission", %{root: root} do
    fixture = fixture(root, "freebsd")

    for {key, value, reason} <- [
          {"image_sha256", String.duplicate("f", 64), "receipt_disk"},
          {"kernel_sha256", String.duplicate("f", 64), "receipt_kernel"},
          {"firmware_sha256", String.duplicate("f", 64), "receipt_firmware"},
          {"vmm_sha256", String.duplicate("f", 64), "receipt_vmm"},
          {"os", "illumos", "receipt_os"},
          {"native_admission", true, "receipt_boundary"}
        ] do
      alter_service(fixture, &Map.put(&1, key, value))
      refused!(fixture, reason)
    end
  end

  test "refuses replayed boot identity and an unclean noncrash exit", %{root: root} do
    fixture = fixture(root, "freebsd")
    boot = "00000000-0000-0000-0000-000000000001"
    alter_service(fixture, &Map.put(&1, "boot_ids", [boot, boot]))
    refused!(fixture, "boot_identity")
    alter_service(fixture, &Map.put(&1, "boot_endings", ["sigkill", "clean"]))
    refused!(fixture, "boot_endings")
  end

  for os <- ~w(freebsd illumos) do
    test "refuses renamed, missing and extra #{os} service oracles", %{root: root} do
      fixture = fixture(root, unquote(os))

      for change <- [
            &Map.update!(&1, "checks", fn [_ | rest] -> ["unchecked-substitute" | rest] end),
            &Map.update!(&1, "checks", fn [_ | rest] -> rest end),
            &Map.update!(&1, "checks", fn checks -> ["unchecked-extra" | checks] end),
            &Map.update!(&1, "checks", fn checks ->
              Enum.map(checks, fn
                "ssh-triggered-clean-guest-shutdown" ->
                  "first-boot-sigkill-and-final-clean-shutdown"

                check ->
                  check
              end)
            end)
          ] do
        alter_service(fixture, change)
        refused!(fixture, "complete_services")
      end
    end
  end

  test "OmniOS refuses FreeBSD's scoped service set", %{root: root} do
    fixture = fixture(root, "illumos")

    alter_service(fixture, fn receipt ->
      Map.update!(receipt, "checks", fn checks ->
        checks --
          ~w(workspace-exact-git-ownership-and-unrelated-root-refusal
            executor-current-heartbeat-withdrawal-before-command-deadline
            executor-whole-group-death-no-result-and-fresh-fence-completion)
      end)
    end)

    refused!(fixture, "complete_services")
  end

  test "refuses a supplemental receipt from a different boot", %{root: root} do
    fixture = fixture(root, "freebsd")
    scenarios = fixture.approval["scenarios"]
    growth = Enum.find(scenarios, &(&1["name"] == "growth"))
    [descriptor] = growth["supporting"]
    receipt = descriptor["path"] |> File.read!() |> JSON.decode!()

    receipt =
      Map.put(receipt, "boot_ids", List.duplicate("00000000-0000-0000-0000-000000000999", 3))

    descriptor = evidence(root, "foreign-growth.json", receipt)

    scenarios =
      Enum.map(
        scenarios,
        &if(&1["name"] == "growth", do: Map.put(&1, "supporting", [descriptor]), else: &1)
      )

    write_json(fixture.approval_path, Map.put(fixture.approval, "scenarios", scenarios))
    refused!(fixture, "supporting_boots")
  end

  test "refuses changed evidence bytes without their reviewed digest", %{root: root} do
    fixture = fixture(root, "freebsd")
    assembly = fixture.approval["assembly"]
    File.write!(assembly["path"], "{}")
    refused!(fixture, "evidence_hash")
  end

  test "structurally complete synthetic evidence cannot select a production identity", %{
    root: root
  } do
    fixture = fixture(root, "freebsd")

    assert_raise ArgumentError, "native image promotion refused: unapproved_image", fn ->
      Promotion.verify_approved!(fixture.approval_path, fixture.output)
    end

    refute File.exists?(Path.join(fixture.output, "manifest.json"))
  end

  test "refuses malformed or linked evidence and extra output files", %{root: root} do
    fixture = fixture(root, "freebsd")
    assembly = fixture.approval["assembly"]
    File.rename!(assembly["path"], assembly["path"] <> ".actual")
    File.ln_s!(assembly["path"] <> ".actual", assembly["path"])
    refused!(fixture, "evidence_file")
    File.rm!(assembly["path"])
    File.rename!(assembly["path"] <> ".actual", assembly["path"])
    File.write!(Path.join(fixture.output, "payload.iso"), "test hook")
    refused!(fixture, "output_files")
  end

  @spec refused!(fixture(), String.t() | nil) :: :ok
  defp refused!(fixture, reason \\ nil) do
    error =
      assert_raise ArgumentError, fn ->
        Promotion.verify!(fixture.approval_path, fixture.output)
      end

    if reason, do: assert(error.message == "native image promotion refused: " <> reason)
    refute File.exists?(Path.join(fixture.output, "manifest.json"))
    :ok
  end

  @spec alter_service(fixture(), (map() -> map())) :: :ok
  defp alter_service(fixture, change) do
    [scenario | rest] = fixture.approval["scenarios"]
    original = scenario["service"]["path"] |> File.read!() |> JSON.decode!()
    descriptor = evidence(fixture.root, "modified-service.json", change.(original))
    scenario = Map.put(scenario, "service", descriptor)
    write_json(fixture.approval_path, Map.put(fixture.approval, "scenarios", [scenario | rest]))
  end

  @spec fixture(String.t(), String.t()) :: fixture()
  defp fixture(root, os) do
    output = Path.join(root, "output")
    File.mkdir!(output)
    disk = "guest disk"
    firmware = "firmware"
    File.write!(Path.join(output, "disk.raw"), disk)
    File.write!(Path.join(output, "firmware"), firmware)

    manifest = %{
      "version" => 6,
      "os" => os,
      "architecture" => "x86_64",
      "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => artifact(firmware)},
      "root" => Map.put(artifact(disk), "format", "raw-gpt"),
      "kernel" => %{
        "bytes" => 17,
        "sha256" => hash("reviewed kernel"),
        "source_revision" => String.duplicate("1", 40),
        "patch_hash" => String.duplicate("2", 64),
        "configuration_hash" => String.duplicate("3", 64),
        "compiler" => "reviewed compiler"
      },
      "guest_agents" => os <> "-v1",
      "minimum_memory_bytes" => 1_073_741_824,
      "minimum_disk_bytes" => 1_073_741_824,
      "workspace_source_version" => 2
    }

    {:ok, image} = ImageManifest.validate(manifest)
    vmm = hash("reviewed VMM")

    scenarios =
      Enum.map(~w(services growth isolation recovery crash-recovery), fn name ->
        count = if name == "growth", do: 3, else: 2

        boots =
          Enum.map(
            1..count,
            &("00000000-0000-0000-0000-" <> String.pad_leading(Integer.to_string(&1), 12, "0"))
          )

        endings =
          if name == "crash-recovery",
            do: ["sigkill", "clean"],
            else: List.duplicate("clean", count)

        common = %{
          "version" => 1,
          "os" => os,
          "native_admission" => false,
          "checks" => ["checked"]
        }

        service =
          Map.merge(common, %{
            "boot_ids" => boots,
            "boot_endings" => endings,
            "image_sha256" => hash(disk),
            "kernel_sha256" => image.kernel.sha256,
            "firmware_sha256" => hash(firmware),
            "vmm_sha256" => vmm,
            "checks" => service_oracles(os, name == "crash-recovery")
          })

        supporting =
          cond do
            name == "services" ->
              []

            name in ~w(isolation recovery) ->
              Enum.with_index(boots, fn boot, index ->
                evidence(root, "#{name}-#{index}.json", Map.put(common, "boot_id", boot))
              end)

            true ->
              [evidence(root, "#{name}-support.json", Map.put(common, "boot_ids", boots))]
          end

        %{
          "name" => name,
          "service" => evidence(root, "#{name}-service.json", service),
          "supporting" => supporting
        }
      end)

    approval = %{
      "version" => 1,
      "image_id" => image.id,
      "manifest" => manifest,
      "vmm_sha256" => vmm,
      "assembly" =>
        evidence(root, "assembly.json", %{"version" => 1, "os" => os, "native_admission" => false}),
      "scenarios" => scenarios
    }

    approval_path = Path.join(root, "approval.json")
    write_json(approval_path, approval)
    %{root: root, output: output, approval: approval, approval_path: approval_path}
  end

  @spec service_oracles(String.t(), boolean()) :: [String.t()]
  defp service_oracles(os, crash?) do
    checks = ~w(
      mmdsv2-current-boot-kernel assigned-address-reachable
      readiness-withheld-without-ssh-authority trust-installed-and-stale-refused
      flush-current-boot-and-refusals workspace-stale-foreign-malformed-refused
      workspace-native-https-shallow-checkout-and-exact-bytes
      terminal-hello-ping-and-refusals
      terminal-managed-pty-input-resize-replay-and-token-refusal
      kernel-current-boot-rechecked complete-readiness-after-isolated-authority
      ssh-certified-host-and-foreign-ca-refusal
      ssh-managed-uid-gid-bash-and-passwordless-sudo
      ssh-foreign-key-root-foreign-user-and-password-refusals
      ssh-login-receipt-before-startup-and-client-environment
      executor-private-https-fixed-command-completed
      new-mmds-epoch-challenge-and-boot-id previous-boot-protocol-refused
      all-boots-complete-service-oracles
    )

    endings =
      if crash? do
        ~w(first-boot-sigkill-and-final-clean-shutdown
          home-bytes-retained-across-abrupt-restart
          ssh-host-key-rotated-across-abrupt-restart)
      else
        ~w(ssh-triggered-clean-guest-shutdown
          home-bytes-retained-across-clean-reboot
          ssh-host-key-rotated-across-clean-reboot)
      end

    additional =
      if os == "illumos" do
        ~w(workspace-exact-git-ownership-and-unrelated-root-refusal
          executor-current-heartbeat-withdrawal-before-command-deadline
          executor-whole-group-death-no-result-and-fresh-fence-completion)
      else
        []
      end

    checks ++ endings ++ additional
  end

  @spec artifact(binary()) :: %{String.t() => pos_integer() | String.t()}
  defp artifact(bytes), do: %{"bytes" => byte_size(bytes), "sha256" => hash(bytes)}

  @spec evidence(String.t(), String.t(), map()) :: %{String.t() => String.t()}
  defp evidence(root, name, value) do
    path = Path.join(root, name)
    bytes = JSON.encode!(value)
    File.write!(path, bytes)
    %{"path" => path, "sha256" => hash(bytes)}
  end

  @spec write_json(String.t(), map()) :: :ok
  defp write_json(path, value), do: File.write!(path, JSON.encode!(value))

  @spec hash(binary()) :: String.t()
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
