defmodule Overalls.NativeImagePromotion do
  @moduledoc "Exact-artifact promotion of separately reviewed native machine evidence."

  alias OverallsProtocol.ImageManifest
  alias OverallsProtocol.NativeAdmission

  @type json :: nil | boolean() | number() | String.t() | [json()] | %{String.t() => json()}
  @type evidence :: %{path: String.t(), sha256: String.t()}
  @type scenario :: %{name: String.t(), service: evidence(), supporting: [evidence()]}
  @type approval :: %{
          image: ImageManifest.native_image(),
          vmm_sha256: String.t(),
          assembly: evidence(),
          scenarios: [scenario()]
        }

  @scenarios ~w(services growth isolation recovery crash-recovery)
  @maximum_json 1_048_576

  # @cc [owner:ghuntley,label:security;verification] native-promotion-manifest-last
  # Verification MUST require the exact native image identity, bytes and reviewed
  # evidence before writing a manifest. Every refusal MUST leave manifest.json
  # absent and expose only a fixed diagnostic, never evidence or guest contents.
  @spec verify!(String.t(), String.t()) :: :ok
  def verify!(approval_path, output) do
    approval = approval_path |> read_json!() |> approval!()
    verify_approval!(approval, output)
  end

  # @cc [owner:ghuntley,label:security;deployment] native-production-promotion-approved-identity
  # Production promotion MUST additionally require the protocol's immutable
  # reviewed-image admission registry before writing any image manifest. The
  # structural evidence verifier alone MUST NOT select a production identity.
  @spec verify_approved!(String.t(), String.t()) :: :ok
  def verify_approved!(approval_path, output) do
    approval = approval_path |> read_json!() |> approval!()
    require!(NativeAdmission.admitted?(approval.image), :unapproved_image)
    verify_approval!(approval, output)
  end

  @spec verify_approval!(approval(), String.t()) :: :ok
  defp verify_approval!(approval, output) do
    require!(Enum.sort(File.ls!(output)) == ["disk.raw", "firmware"], :output_files)

    for {name, descriptor} <- ImageManifest.artifact_files(approval.image) do
      verify_artifact!(Path.join(output, name), descriptor)
    end

    assembly = evidence!(approval.assembly)
    require!(assembly["version"] == 1, :assembly_version)
    require!(assembly["os"] == Atom.to_string(approval.image.os), :assembly_os)
    require!(assembly["native_admission"] == false, :assembly_boundary)

    for scenario <- approval.scenarios do
      verify_scenario!(scenario, approval)
    end

    File.write!(Path.join(output, "manifest.json"), JSON.encode!(approval.image.manifest) <> "\n")
    :ok
  rescue
    _error in File.Error -> refuse!(:filesystem)
  end

  @spec approval!(term()) :: approval()
  defp approval!(value) do
    require!(keys?(value, ~w(version image_id manifest vmm_sha256 assembly scenarios)), :approval)
    require!(value["version"] == 1, :approval_version)

    image =
      case ImageManifest.validate(value["manifest"]) do
        {:ok, %{manifest: %{"version" => 6}, os: os} = image} when os in [:freebsd, :illumos] ->
          image

        _ ->
          refuse!(:manifest)
      end

    require!(image.id == value["image_id"], :image_id)
    require!(digest?(value["vmm_sha256"]), :vmm_digest)
    scenarios = value["scenarios"]
    require!(is_list(scenarios) and length(scenarios) == length(@scenarios), :scenarios)
    scenarios = Enum.map(scenarios, &scenario!/1)
    require!(Enum.sort(Enum.map(scenarios, & &1.name)) == Enum.sort(@scenarios), :scenario_set)

    %{
      image: image,
      vmm_sha256: value["vmm_sha256"],
      assembly: descriptor!(value["assembly"]),
      scenarios: scenarios
    }
  end

  @spec scenario!(term()) :: scenario()
  defp scenario!(value) do
    require!(keys?(value, ~w(name service supporting)), :scenario)
    require!(value["name"] in @scenarios, :scenario_name)
    supporting = value["supporting"]
    count = if value["name"] in ~w(isolation recovery), do: 2, else: 1
    count = if value["name"] == "services", do: 0, else: count
    require!(is_list(supporting) and length(supporting) == count, :supporting_count)

    %{
      name: value["name"],
      service: descriptor!(value["service"]),
      supporting: Enum.map(supporting, &descriptor!/1)
    }
  end

  @spec descriptor!(term()) :: evidence()
  defp descriptor!(value) do
    require!(keys?(value, ~w(path sha256)), :evidence_descriptor)
    require!(is_binary(value["path"]) and byte_size(value["path"]) in 1..4096, :evidence_path)
    require!(Path.type(value["path"]) == :absolute, :evidence_path)
    require!(digest?(value["sha256"]), :evidence_digest)
    %{path: value["path"], sha256: value["sha256"]}
  end

  @spec verify_scenario!(scenario(), approval()) :: :ok
  defp verify_scenario!(scenario, approval) do
    receipt = evidence!(scenario.service)
    common_receipt!(receipt, approval)
    require!(receipt["image_sha256"] == approval.image.manifest["root"]["sha256"], :receipt_disk)
    require!(receipt["kernel_sha256"] == approval.image.kernel.sha256, :receipt_kernel)

    require!(
      receipt["firmware_sha256"] == approval.image.manifest["boot"]["firmware"]["sha256"],
      :receipt_firmware
    )

    require!(receipt["vmm_sha256"] == approval.vmm_sha256, :receipt_vmm)
    boot_ids = receipt["boot_ids"]
    count = if scenario.name == "growth", do: 3, else: 2
    require!(is_list(boot_ids) and length(boot_ids) == count, :boot_count)
    require!(Enum.all?(boot_ids, &boot_id?/1) and Enum.uniq(boot_ids) == boot_ids, :boot_identity)

    endings =
      if scenario.name == "crash-recovery",
        do: ["sigkill", "clean"],
        else: List.duplicate("clean", count)

    require!(receipt["boot_endings"] == endings, :boot_endings)

    require!(
      Enum.sort(receipt["checks"]) ==
        Enum.sort(service_checks(approval.image, scenario.name == "crash-recovery")),
      :complete_services
    )

    bound_boots =
      Enum.flat_map(scenario.supporting, fn descriptor ->
        supporting = evidence!(descriptor)
        common_receipt!(supporting, approval)

        cond do
          is_list(supporting["boot_ids"]) ->
            require!(supporting["boot_ids"] == boot_ids, :supporting_boots)
            boot_ids

          is_binary(supporting["boot_id"]) ->
            require!(supporting["boot_id"] in boot_ids, :supporting_boot)
            [supporting["boot_id"]]

          true ->
            refuse!(:supporting_identity)
        end
      end)

    if scenario.supporting != [] do
      require!(Enum.sort(bound_boots) == Enum.sort(boot_ids), :supporting_coverage)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:security;verification] native-promotion-complete-service-oracles
  # Every service receipt MUST name the exact reviewed oracle set, including the
  # scenario's clean or abrupt shutdown checks. The immutable FreeBSD approval
  # retains its 22 recorded checks; OmniOS MUST additionally verify workspace
  # ownership and executor heartbeat withdrawal and whole-group cancellation.
  # Explicit version-1 Git identity images MUST require those three oracles on
  # both OS families and current-MMDS Git configuration/commit attribution.
  # Equal-length unknown checks MUST NOT substitute for any required oracle.
  @spec service_checks(ImageManifest.native_image(), boolean()) :: [String.t()]
  defp service_checks(image, crash?) do
    git_identity? = Map.get(image, :git_identity_version) === 1
    common = ~w(
      mmdsv2-current-boot-kernel
      assigned-address-reachable
      readiness-withheld-without-ssh-authority
      trust-installed-and-stale-refused
      flush-current-boot-and-refusals
      workspace-stale-foreign-malformed-refused
      workspace-native-https-shallow-checkout-and-exact-bytes
      terminal-hello-ping-and-refusals
      terminal-managed-pty-input-resize-replay-and-token-refusal
      kernel-current-boot-rechecked
      complete-readiness-after-isolated-authority
      ssh-certified-host-and-foreign-ca-refusal
      ssh-managed-uid-gid-bash-and-passwordless-sudo
      ssh-foreign-key-root-foreign-user-and-password-refusals
      ssh-login-receipt-before-startup-and-client-environment
      executor-private-https-fixed-command-completed
      new-mmds-epoch-challenge-and-boot-id
      previous-boot-protocol-refused
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
      if image.os == :illumos or git_identity? do
        ~w(workspace-exact-git-ownership-and-unrelated-root-refusal
            executor-current-heartbeat-withdrawal-before-command-deadline
            executor-whole-group-death-no-result-and-fresh-fence-completion)
      else
        []
      end

    attribution =
      if git_identity?,
        do: ["all-boots-current-mmds-git-config-and-commit-attribution"],
        else: []

    common ++ endings ++ additional ++ attribution
  end

  @spec common_receipt!(map(), approval()) :: :ok
  defp common_receipt!(receipt, approval) do
    require!(receipt["version"] == 1, :receipt_version)
    require!(receipt["os"] == Atom.to_string(approval.image.os), :receipt_os)
    require!(receipt["native_admission"] == false, :receipt_boundary)
    checks = receipt["checks"]
    require!(is_list(checks) and length(checks) in 1..64, :receipt_checks)
    require!(Enum.all?(checks, &(is_binary(&1) and byte_size(&1) in 1..256)), :receipt_checks)
    require!(Enum.uniq(checks) == checks, :receipt_checks)
    :ok
  end

  @spec evidence!(evidence()) :: map()
  defp evidence!(descriptor) do
    bytes = read_regular!(descriptor.path, @maximum_json)
    require!(hash(bytes) == descriptor.sha256, :evidence_hash)
    value = decode!(bytes)
    require!(is_map(value), :evidence_json)
    value
  end

  @spec verify_artifact!(String.t(), map()) :: :ok
  defp verify_artifact!(path, descriptor) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        require!(size == descriptor["bytes"], :artifact_size)

      _ ->
        refuse!(:artifact_file)
    end

    digest =
      path
      |> File.stream!(1_048_576, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    require!(digest == descriptor["sha256"], :artifact_hash)
    :ok
  end

  @spec read_json!(String.t()) :: json()
  defp read_json!(path), do: path |> read_regular!(@maximum_json) |> decode!()

  @spec read_regular!(String.t(), pos_integer()) :: binary()
  defp read_regular!(path, limit) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= limit ->
        case File.read(path) do
          {:ok, bytes} when byte_size(bytes) == size -> bytes
          _ -> refuse!(:evidence_file)
        end

      _ ->
        refuse!(:evidence_file)
    end
  end

  @spec decode!(binary()) :: json()
  defp decode!(bytes) do
    case JSON.decode(bytes) do
      {:ok, value} -> value
      _ -> refuse!(:json)
    end
  end

  @spec keys?(term(), [String.t()]) :: boolean()
  defp keys?(value, expected),
    do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(expected)

  @spec boot_id?(term()) :: boolean()
  defp boot_id?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f-]{36}\z/, value)
  defp boot_id?(_), do: false

  @spec digest?(term()) :: boolean()
  defp digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest?(_), do: false

  @spec hash(binary()) :: String.t()
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @spec require!(boolean(), atom()) :: :ok
  defp require!(true, _reason), do: :ok
  defp require!(_, reason), do: refuse!(reason)

  @spec refuse!(atom()) :: no_return()
  defp refuse!(reason), do: raise(ArgumentError, "native image promotion refused: #{reason}")
end
