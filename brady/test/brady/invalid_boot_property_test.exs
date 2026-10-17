defmodule Brady.InvalidBootPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag timeout: 240_000
  @probe Path.expand("../../scripts/invalid_boot_probe.exs", __DIR__)
  @fields ~w(version host_id issuer_cert_file issuer_key_file upstream_ca_file protected_cidrs tls_exceptions cache_directory cache_dataset cache_quota_bytes)
  @paths ~w(issuer_cert_file issuer_key_file upstream_ca_file cache_directory)
  @config_cases [
    :missing,
    :malformed,
    :oversized,
    :non_object,
    :unknown_field,
    :version,
    :host,
    :dataset,
    :quota_low,
    :quota_high,
    :quota_type,
    :cidr,
    :cidr_type,
    :exception_host,
    :exception_port,
    :exception_extra,
    :exceptions_type,
    :exceptions_count
  ]
  @path_cases Enum.flat_map([:relative, :noncanonical, :long_path], fn kind ->
                Enum.map(@paths, &{kind, &1})
              end)
  @cases @config_cases ++ @path_cases ++ Enum.map(@fields, &{:missing_field, &1})
  @signing_cases Enum.flat_map(~w(issuer_cert_file issuer_key_file), fn field ->
                   Enum.map(
                     [
                       :missing,
                       :empty,
                       :public,
                       :symlink,
                       :hardlink,
                       :oversized,
                       :malformed
                     ],
                     &{&1, field}
                   )
                 end)
  @signing @signing_cases ++ [:mismatched, :non_ca, :non_signing]
  @projection_fields ~w(supervisor_attempted signer_attempted cache_attempted listener_attempted metrics_attempted rejection_event supervisor metrics_only signer cache metrics cache_directory)
  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{String.t() => json_value()}
  @type config_mutation ::
          :missing
          | :malformed
          | :oversized
          | :non_object
          | :unknown_field
          | :version
          | :host
          | :dataset
          | :quota_low
          | :quota_high
          | :quota_type
          | :cidr
          | :cidr_type
          | :exception_host
          | :exception_port
          | :exception_extra
          | :exceptions_type
          | :exceptions_count
          | {:relative | :noncanonical | :long_path | :missing_field, String.t()}
  @type signing_mutation ::
          :mismatched
          | :non_ca
          | :non_signing
          | {:missing | :empty | :public | :symlink | :hardlink | :oversized | :malformed,
             String.t()}
  @type fixture_snapshot :: [
          {String.t(), atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), binary()}
        ]
  @type boot_projection :: %{String.t() => String.t() | boolean()}

  # @cc [owner:ghuntley,label:security;verification] generated-brady-config-boot-refusal
  # Invalid schema/file configurations MUST reject fresh OTP startup before the
  # named supervisor or reviewed signer/cache/listener/metrics startup calls.
  # Refusal MUST preserve owned fixture custody and exclude fixture material
  # from diagnostics. Unset MUST remain a separate Metrics-only boot.
  property "generated invalid Brady configurations refuse fresh OTP startup" do
    root = private_directory("k-bc-")
    on_exit(fn -> File.rm_rf!(root) end)

    check all(
            order <- shuffle(@cases),
            quota <- member_of([1_048_576, 1_048_577, 274_877_906_944]),
            max_runs: 3
          ) do
      for mutation <- order do
        directory = child_directory(root)
        config = configuration(directory, quota)
        path = Path.join(directory, "config.json")
        write_config(path, config)
        assert {:ok, _} = Brady.Config.load(path)
        mutate_config(mutation, path, config)
        assert_boot(path, config, "configuration_rejected", false, false, true)
      end
    end
  end

  # @cc [owner:ghuntley,label:security;verification] generated-brady-signer-boot-refusal
  # Invalid signer files MUST fail the first supervised child before cache or
  # listener startup. Supervisor/signer attempts are expected; configuration
  # rejection events MUST NOT be required for this later child failure.
  property "generated invalid Brady signer material refuses before listeners" do
    root = private_directory("k-bs-")
    on_exit(fn -> File.rm_rf!(root) end)

    check all(order <- shuffle(@signing), max_runs: 3) do
      for mutation <- order do
        directory = child_directory(root)
        config = configuration(directory, 1_048_576)
        path = Path.join(directory, "config.json")
        write_config(path, config)
        assert {:ok, _} = Brady.Config.load(path)

        assert {:ok, signer} =
                 Brady.TLS.Certificates.start_link(
                   certfile: config["issuer_cert_file"],
                   keyfile: config["issuer_key_file"]
                 )

        GenServer.stop(signer)
        original = material(config)
        mutate_signing(mutation, config)
        assert {:ok, _} = Brady.Config.load(path)
        assert_boot(path, config, "signing_rejected", true, true, false, original)
      end
    end
  end

  test "unset Brady configuration starts only Metrics" do
    root = private_directory("k-bu-")
    on_exit(fn -> File.rm_rf!(root) end)
    {output, status} = boot(nil, root, Path.join(root, "cache"))
    assert status == 0
    assert projection(output) == expected("started", true, false, false, true)
  end

  # @cc [owner:ghuntley,label:security;verification] brady-immutable-key-loader-only
  # Immutable-store key refusal MUST use only the loader without attempting
  # signer startup or reading material outside the disposable fixture.
  property "generated immutable store issuer key paths are rejected by the loader" do
    root = private_directory("k-bl-")
    on_exit(fn -> File.rm_rf!(root) end)

    check all(suffix <- string(:alphanumeric, min_length: 8, max_length: 32), max_runs: 20) do
      config = configuration(root, 1_048_576)
      path = Path.join(root, "config.json")
      write_config(path, config)
      assert {:ok, _} = Brady.Config.load(path)
      write_config(path, Map.put(config, "issuer_key_file", "/nix/store/" <> suffix <> ".key"))
      before = snapshot(root)
      rejected? = match?({:error, :invalid_configuration}, Brady.Config.load(path))
      assert rejected?, "immutable key path was accepted by the loader"
      assert snapshot(root) == before
    end
  end

  @spec assert_boot(Path.t(), json_object(), String.t(), boolean(), boolean(), boolean(), [
          String.t()
        ]) :: :ok
  defp assert_boot(path, config, outcome, supervisor, signer, rejected, original \\ []) do
    directory = Path.dirname(path)
    private = original ++ material(config) ++ [directory, "-----BEGIN", "-----END"]
    before = snapshot(directory)
    {output, status} = boot(path, directory, config["cache_directory"])
    assert status == 0
    assert projection(output) == expected(outcome, supervisor, signer, rejected, false)
    private? = not Enum.any?(private, &String.contains?(output, &1))
    assert private?, "boot diagnostics exposed fixture material or paths"
    assert snapshot(directory) == before
    :ok
  end

  @spec expected(String.t(), boolean(), boolean(), boolean(), boolean()) :: boot_projection()
  defp expected(outcome, attempted, signer_attempted, rejected, started) do
    %{
      "outcome" => outcome,
      "supervisor_attempted" => attempted,
      "signer_attempted" => signer_attempted,
      "cache_attempted" => false,
      "listener_attempted" => false,
      "metrics_attempted" => started,
      "rejection_event" => rejected,
      "supervisor" => started,
      "metrics_only" => started,
      "signer" => false,
      "cache" => false,
      "metrics" => started,
      "cache_directory" => false
    }
  end

  @spec boot(Path.t() | nil, Path.t(), Path.t()) :: {String.t(), non_neg_integer()}
  defp boot(path, root, cache) do
    System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", @probe],
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"OVERALLS_BOOT_PROBE", "test"},
        {"OVERALLS_PROBE_ROOT", root},
        {"OVERALLS_PROBE_CACHE", cache},
        {"BRADY_CONFIG_FILE", path},
        {"BRADY_FLEET_MONITOR", nil},
        {"BRADY_SLO_EXPORT", nil},
        {"INVOCATION_ID", nil}
      ],
      stderr_to_stdout: true
    )
  end

  @spec projection(String.t()) :: boot_projection()
  defp projection(output) do
    lines = output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "BOOT_PROBE:"))

    decoded =
      case lines do
        [line] -> JSON.decode(String.replace_prefix(line, "BOOT_PROBE:", ""))
        _ -> :invalid
      end

    case decoded do
      {:ok, %{"outcome" => outcome} = value}
      when map_size(value) == 13 and
             outcome in ["configuration_rejected", "signing_rejected", "started", "other"] ->
        fields = Map.delete(value, "outcome")

        valid? =
          Enum.sort(Map.keys(fields)) == Enum.sort(@projection_fields) and
            Enum.all?(Map.values(fields), &is_boolean/1)

        assert valid?, "invalid boot probe projection"
        value

      _ ->
        flunk("invalid boot probe projection")
    end
  end

  @spec private_directory(String.t()) :: Path.t()
  defp private_directory(prefix) do
    root = Path.join(System.tmp_dir!(), prefix <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  @spec child_directory(Path.t()) :: Path.t()
  defp child_directory(root) do
    directory = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    directory
  end

  @spec configuration(Path.t(), pos_integer()) :: json_object()
  defp configuration(root, quota) do
    key = X509.PrivateKey.new_ec(:secp256r1)
    cert = X509.Certificate.self_signed(key, "/CN=Disposable Brady Issuer", template: :root_ca)
    certfile = Path.join(root, "issuer.pem")
    keyfile = Path.join(root, "issuer.key")
    File.write!(certfile, X509.Certificate.to_pem(cert))
    File.write!(keyfile, X509.PrivateKey.to_pem(key))
    File.chmod!(certfile, 0o600)
    File.chmod!(keyfile, 0o600)

    %{
      "version" => 1,
      "host_id" => "11111111-1111-4111-8111-111111111111",
      "issuer_cert_file" => certfile,
      "issuer_key_file" => keyfile,
      "upstream_ca_file" => certfile,
      "protected_cidrs" => ["8.8.8.0/24"],
      "tls_exceptions" => [],
      "cache_directory" => Path.join(root, "cache"),
      "cache_dataset" => "tank/brady-fixture",
      "cache_quota_bytes" => quota
    }
  end

  @spec material(json_object()) :: [String.t()]
  defp material(config) do
    for field <- ~w(issuer_cert_file issuer_key_file),
        {:ok, bytes} <- [File.read(config[field])],
        bytes != "" do
      bytes
    end
  end

  @spec snapshot(Path.t()) :: fixture_snapshot()
  defp snapshot(root) do
    stat = File.lstat!(root)

    [
      {".", stat.type, stat.mode, stat.links, stat.uid, stat.gid, :crypto.hash(:sha256, "")}
      | snapshot_entries(root, "")
    ]
  end

  @spec snapshot_entries(Path.t(), String.t()) :: fixture_snapshot()
  defp snapshot_entries(root, relative) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      child = Path.join(relative, name)
      path = Path.join(root, child)
      stat = File.lstat!(path)

      {bytes, descendants} =
        case stat.type do
          :regular -> {File.read!(path), []}
          :directory -> {"", snapshot_entries(root, child)}
          :symlink -> {File.read_link!(path), []}
          _ -> flunk("boot changed fixture file types")
        end

      [
        {child, stat.type, stat.mode, stat.links, stat.uid, stat.gid,
         :crypto.hash(:sha256, bytes)}
        | descendants
      ]
    end)
  end

  @spec write_config(Path.t(), json_object()) :: :ok
  defp write_config(path, config), do: File.write!(path, JSON.encode!(config))

  @spec mutate_config(config_mutation(), Path.t(), json_object()) :: :ok
  defp mutate_config(:missing, path, _), do: File.rm!(path)
  defp mutate_config(:malformed, path, _), do: File.write!(path, "{invalid")

  defp mutate_config(:oversized, path, config),
    do: File.write!(path, JSON.encode!(config) <> String.duplicate(" ", 65_537))

  defp mutate_config(:non_object, path, _), do: File.write!(path, "[]")

  defp mutate_config({:missing_field, field}, path, config),
    do: write_config(path, Map.delete(config, field))

  defp mutate_config({:relative, field}, path, config),
    do: write_config(path, Map.put(config, field, "relative"))

  defp mutate_config({:noncanonical, field}, path, config),
    do:
      write_config(
        path,
        Map.put(
          config,
          field,
          Path.dirname(config[field]) <> "/./" <> Path.basename(config[field])
        )
      )

  defp mutate_config({:long_path, field}, path, config),
    do: write_config(path, Map.put(config, field, config[field] <> String.duplicate("x", 4097)))

  defp mutate_config(kind, path, config) do
    {field, value} =
      case kind do
        :unknown_field ->
          {"socket_options", []}

        :version ->
          {"version", 0}

        :host ->
          {"host_id", "not-a-host"}

        :dataset ->
          {"cache_dataset", "tank/../escape"}

        :quota_low ->
          {"cache_quota_bytes", 1_048_575}

        :quota_high ->
          {"cache_quota_bytes", 274_877_906_945}

        :quota_type ->
          {"cache_quota_bytes", "1048576"}

        :cidr ->
          {"protected_cidrs", ["10.1.0.0/8"]}

        :cidr_type ->
          {"protected_cidrs", "8.8.8.0/24"}

        :exception_host ->
          {"tls_exceptions", [%{"host" => "*.example", "port" => 443}]}

        :exception_port ->
          {"tls_exceptions", [%{"host" => "pinned.example", "port" => 0}]}

        :exception_extra ->
          {"tls_exceptions", [%{"host" => "pinned.example", "port" => 443, "bypass" => true}]}

        :exceptions_type ->
          {"tls_exceptions", %{}}

        :exceptions_count ->
          {"tls_exceptions", List.duplicate(%{"host" => "pinned.example", "port" => 443}, 257)}
      end

    write_config(path, Map.put(config, field, value))
  end

  @spec mutate_signing(signing_mutation(), json_object()) :: :ok
  defp mutate_signing({kind, field}, config) do
    path = config[field]

    case kind do
      :missing ->
        File.rm!(path)

      :empty ->
        File.write!(path, "")

      :public ->
        File.chmod!(path, 0o644)

      :symlink ->
        File.rename!(path, path <> ".target")
        File.ln_s!(path <> ".target", path)

      :hardlink ->
        File.ln!(path, path <> ".link")

      :oversized ->
        File.write!(path, File.read!(path) <> String.duplicate("x", 65_537))

      :malformed ->
        File.write!(path, "invalid-signing-material")
    end
  end

  defp mutate_signing(:mismatched, config),
    do:
      File.write!(
        config["issuer_key_file"],
        X509.PrivateKey.to_pem(X509.PrivateKey.new_ec(:secp256r1))
      )

  defp mutate_signing(kind, config) when kind in [:non_ca, :non_signing] do
    {:ok, key} = X509.PrivateKey.from_pem(File.read!(config["issuer_key_file"]))

    opts =
      case kind do
        :non_ca ->
          [template: :server]

        :non_signing ->
          [
            template: :root_ca,
            extensions: [key_usage: X509.Certificate.Extension.key_usage([:digitalSignature])]
          ]
      end

    cert = X509.Certificate.self_signed(key, "/CN=Disposable Brady Issuer", opts)
    File.write!(config["issuer_cert_file"], X509.Certificate.to_pem(cert))
  end
end
