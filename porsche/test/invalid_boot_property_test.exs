defmodule Porsche.InvalidBootPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag timeout: 240_000
  @probe Path.expand("../scripts/invalid_boot_probe.exs", __DIR__)
  @required ~w(version control_plane public_origin credential_file host_key_dir)
  @origins ~w(control_plane public_origin)
  @paths ~w(credential_file host_key_dir status_socket)
  @base_cases [
    :missing,
    :malformed,
    :oversized,
    :non_object,
    :unknown_field,
    :version,
    :config_writable,
    :config_symlink,
    :credential_missing,
    :credential_empty,
    :credential_public,
    :credential_symlink,
    :credential_hardlink,
    :credential_length,
    :credential_multiline,
    :keydir_missing,
    :keydir_public,
    :keydir_symlink,
    :key_missing,
    :key_public,
    :key_symlink,
    :key_hardlink,
    :port_low,
    :port_high,
    :port_type,
    :bind_type,
    :bind_noncanonical,
    :socket_parent_public,
    :missing_ca,
    :malformed_ca,
    :writable_ca
  ]
  @origin_cases Enum.flat_map(@origins, fn field ->
                  Enum.map([:insecure, :path, :userinfo, :query, :fragment, :ipv6], &{&1, field})
                end)
  @path_cases Enum.flat_map(@paths, fn field ->
                Enum.map([:relative, :noncanonical, :long_path], &{&1, field})
              end)
  @cases @base_cases ++ @origin_cases ++ @path_cases ++ Enum.map(@required, &{:missing_field, &1})
  @projection_fields ~w(supervisor_attempted listener_attempted status_attempted observability_attempted supervisor base_present base_only listener socket)
  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{String.t() => json_value()}
  @type mutation ::
          :missing
          | :malformed
          | :oversized
          | :non_object
          | :unknown_field
          | :version
          | :config_writable
          | :config_symlink
          | :credential_missing
          | :credential_empty
          | :credential_public
          | :credential_symlink
          | :credential_hardlink
          | :credential_length
          | :credential_multiline
          | :keydir_missing
          | :keydir_public
          | :keydir_symlink
          | :key_missing
          | :key_public
          | :key_symlink
          | :key_hardlink
          | :port_low
          | :port_high
          | :port_type
          | :bind_type
          | :bind_noncanonical
          | :socket_parent_public
          | :missing_ca
          | :malformed_ca
          | :writable_ca
          | {:insecure
             | :path
             | :userinfo
             | :query
             | :fragment
             | :ipv6
             | :relative
             | :noncanonical
             | :long_path
             | :missing_field, String.t()}
  @type fixture_snapshot :: [
          {String.t(), atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), binary()}
        ]
  @type boot_projection :: %{String.t() => String.t() | boolean()}

  # @cc [owner:ghuntley,label:security;verification] generated-porsche-boot-refusal
  # Invalid configured runtimes MUST refuse fresh OTP startup before the named
  # supervisor or reviewed listener/status/observability starts. Rejection MUST
  # preserve recursive fixture custody and exclude original/mutated credentials,
  # host-key bytes and fixture paths from diagnostics. Unset is base-only startup.
  property "generated invalid Porsche configurations refuse fresh OTP startup" do
    root = private_directory("k-pb-")
    on_exit(fn -> File.rm_rf!(root) end)
    ca = disposable_ca(root)

    check all(
            order <- shuffle(@cases),
            bytes <- binary(length: 32),
            newline <- boolean(),
            invalid_length <- member_of([58, 60, 257]),
            max_runs: 3
          ) do
      token = "porsche_gateway_" <> Base.url_encode64(bytes, padding: false)

      for mutation <- order do
        directory = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
        File.mkdir!(directory)
        File.chmod!(directory, 0o700)
        config = configuration(directory, token, newline, ca)
        path = Path.join(directory, "config.json")
        write_config(path, config)
        assert {:ok, _} = Porsche.Config.load(path)
        original = material(config)
        mutate(mutation, path, config, invalid_length)
        private = [token, directory | original ++ material(config)]
        before = snapshot(directory)
        {output, status} = boot(path, directory, config["status_socket"])
        assert status == 0
        assert projection(output) == expected("rejected", false)
        private? = not Enum.any?(private, &String.contains?(output, &1))
        assert private?, "boot diagnostics exposed fixture material or paths"
        assert snapshot(directory) == before
      end
    end
  end

  test "unset Porsche configuration starts base infrastructure without listeners" do
    root = private_directory("k-pu-")
    on_exit(fn -> File.rm_rf!(root) end)
    {output, status} = boot(nil, root, Path.join(root, "socket"))
    assert status == 0
    assert projection(output) == expected("started", true)
  end

  @spec expected(String.t(), boolean()) :: boot_projection()
  defp expected(outcome, started) do
    %{
      "outcome" => outcome,
      "supervisor_attempted" => started,
      "listener_attempted" => false,
      "status_attempted" => false,
      "observability_attempted" => started,
      "supervisor" => started,
      "base_present" => started,
      "base_only" => started,
      "listener" => false,
      "socket" => false
    }
  end

  @spec boot(Path.t() | nil, Path.t(), Path.t()) :: {String.t(), non_neg_integer()}
  defp boot(path, root, socket) do
    System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", @probe],
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"OVERALLS_BOOT_PROBE", "test"},
        {"OVERALLS_PROBE_ROOT", root},
        {"OVERALLS_PROBE_SOCKET", socket},
        {"PORSCHE_CONFIG_FILE", path},
        {"PORSCHE_SLO_SNAPSHOT", nil}
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
      when map_size(value) == 10 and outcome in ["rejected", "started", "other"] ->
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

  @spec configuration(Path.t(), String.t(), boolean(), String.t()) :: json_object()
  defp configuration(root, token, newline, ca) do
    keys = Path.join(root, "keys")
    File.mkdir!(keys)
    File.chmod!(keys, 0o700)
    credential = Path.join(root, "credential")
    File.write!(credential, token <> if(newline, do: "\n", else: ""))
    File.chmod!(credential, 0o600)
    key = Path.join(keys, "ssh_host_ed25519_key")
    File.write!(key, "synthetic-private-host-key-" <> token)
    File.chmod!(key, 0o600)
    ca_file = Path.join(root, "ca.pem")
    File.write!(ca_file, ca)
    File.chmod!(ca_file, 0o644)

    %{
      "version" => 1,
      "control_plane" => "https://control.example.test",
      "public_origin" => "https://public.example.test",
      "credential_file" => credential,
      "host_key_dir" => keys,
      "bind" => "127.0.0.1",
      "port" => 22222,
      "status_socket" => Path.join(root, "socket"),
      "cacertfile" => ca_file
    }
  end

  @spec material(json_object()) :: [String.t()]
  defp material(config) do
    paths = [
      config["credential_file"],
      Path.join(config["host_key_dir"], "ssh_host_ed25519_key"),
      config["cacertfile"]
    ]

    for path <- paths, {:ok, bytes} <- [File.read(path)], bytes != "" do
      bytes
    end
  end

  @spec write_config(Path.t(), json_object()) :: :ok
  defp write_config(path, config) do
    File.write!(path, JSON.encode!(config))
    File.chmod!(path, 0o600)
  end

  @spec mutate(mutation(), Path.t(), json_object(), pos_integer()) :: :ok
  defp mutate(:missing, path, _, _), do: File.rm!(path)
  defp mutate(:malformed, path, _, _), do: File.write!(path, "{invalid")

  defp mutate(:oversized, path, config, _),
    do: File.write!(path, JSON.encode!(config) <> String.duplicate(" ", 16_385))

  defp mutate(:non_object, path, _, _), do: File.write!(path, "[]")
  defp mutate(:config_writable, path, _, _), do: File.chmod!(path, 0o666)
  defp mutate(:config_symlink, path, _, _), do: symlink(path)
  defp mutate(:credential_missing, _, config, _), do: File.rm!(config["credential_file"])
  defp mutate(:credential_empty, _, config, _), do: File.write!(config["credential_file"], "")
  defp mutate(:credential_public, _, config, _), do: File.chmod!(config["credential_file"], 0o644)
  defp mutate(:credential_symlink, _, config, _), do: symlink(config["credential_file"])

  defp mutate(:credential_hardlink, _, config, _),
    do: File.ln!(config["credential_file"], config["credential_file"] <> ".link")

  defp mutate(:credential_length, _, config, length) do
    bytes = String.trim_trailing(File.read!(config["credential_file"]), "\n")

    File.write!(
      config["credential_file"],
      String.slice(bytes <> String.duplicate("x", 257), 0, length)
    )
  end

  defp mutate(:credential_multiline, _, config, _),
    do: File.write!(config["credential_file"], File.read!(config["credential_file"]) <> "\n\n")

  defp mutate(:keydir_missing, _, config, _) do
    File.rm_rf!(config["host_key_dir"])
    :ok
  end

  defp mutate(:keydir_public, _, config, _), do: File.chmod!(config["host_key_dir"], 0o755)
  defp mutate(:keydir_symlink, _, config, _), do: symlink(config["host_key_dir"])

  defp mutate(:key_missing, _, config, _),
    do: File.rm!(Path.join(config["host_key_dir"], "ssh_host_ed25519_key"))

  defp mutate(:key_public, _, config, _),
    do: File.chmod!(Path.join(config["host_key_dir"], "ssh_host_ed25519_key"), 0o644)

  defp mutate(:key_symlink, _, config, _),
    do: symlink(Path.join(config["host_key_dir"], "ssh_host_ed25519_key"))

  defp mutate(:key_hardlink, _, config, _) do
    path = Path.join(config["host_key_dir"], "ssh_host_ed25519_key")
    File.ln!(path, path <> ".link")
  end

  defp mutate(:socket_parent_public, path, _, _), do: File.chmod!(Path.dirname(path), 0o755)

  defp mutate({:missing_field, field}, path, config, _),
    do: write_config(path, Map.delete(config, field))

  defp mutate({:relative, field}, path, config, _),
    do: write_config(path, Map.put(config, field, "relative"))

  defp mutate({:noncanonical, field}, path, config, _),
    do:
      write_config(
        path,
        Map.put(
          config,
          field,
          Path.dirname(config[field]) <> "/./" <> Path.basename(config[field])
        )
      )

  defp mutate({:long_path, field}, path, config, _),
    do: write_config(path, Map.put(config, field, config[field] <> String.duplicate("x", 4097)))

  defp mutate({kind, field}, path, config, _) when field in @origins do
    value =
      case kind do
        :insecure -> "http://control.example.test"
        :path -> "https://control.example.test/path"
        :userinfo -> "https://user@control.example.test"
        :query -> "https://control.example.test?query"
        :fragment -> "https://control.example.test#fragment"
        :ipv6 -> "https://[::1]"
      end

    write_config(path, Map.put(config, field, value))
  end

  defp mutate(:missing_ca, _, config, _), do: File.rm!(config["cacertfile"])

  defp mutate(:malformed_ca, _, config, _),
    do: File.write!(config["cacertfile"], "synthetic-invalid-ca-marker")

  defp mutate(:writable_ca, _, config, _), do: File.chmod!(config["cacertfile"], 0o666)

  defp mutate(kind, path, config, _) do
    {field, value} =
      case kind do
        :unknown_field ->
          {"credential", String.trim_trailing(File.read!(config["credential_file"]), "\n")}

        :version ->
          {"version", 0}

        :port_low ->
          {"port", 0}

        :port_high ->
          {"port", 65_536}

        :port_type ->
          {"port", "22"}

        :bind_type ->
          {"bind", nil}

        :bind_noncanonical ->
          {"bind", "127.000.0.1"}
      end

    write_config(path, Map.put(config, field, value))
  end

  @spec symlink(Path.t()) :: :ok
  defp symlink(path) do
    File.rename!(path, path <> ".target")
    File.ln_s!(path <> ".target", path)
  end

  # @cc [owner:ghuntley,label:verification;security] porsche-ca-fixture-validity
  # The CA permission mutation MUST start with valid PEM certificate bytes.
  # CA generation MUST stay inside the private fixture and captured tool output
  # MUST NOT be emitted, including on failure.
  @spec disposable_ca(Path.t()) :: String.t()
  defp disposable_ca(root) do
    path = Path.join(root, "fixture-ca.pem")

    {_output, status} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "ec",
          "-pkeyopt",
          "ec_paramgen_curve:prime256v1",
          "-nodes",
          "-days",
          "1",
          "-subj",
          "/CN=Disposable Porsche CA",
          "-keyout",
          Path.join(root, "fixture-ca.key"),
          "-out",
          path
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "disposable CA generation failed"
    bytes = File.read!(path)
    assert String.valid?(bytes), "disposable CA fixture is not UTF-8 PEM"

    valid? =
      case :public_key.pem_decode(bytes) do
        [{:Certificate, der, :not_encrypted}] ->
          match?({:OTPCertificate, _, _, _}, :public_key.pkix_decode_cert(der, :otp))

        _ ->
          false
      end

    assert valid?, "disposable CA fixture is invalid"
    bytes
  end

  @spec private_directory(String.t()) :: Path.t()
  defp private_directory(prefix) do
    root = Path.join(System.tmp_dir!(), prefix <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
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
end
