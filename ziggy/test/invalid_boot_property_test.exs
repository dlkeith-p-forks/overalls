defmodule Ziggy.InvalidBootPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  @moduletag timeout: 240_000
  @probe Path.expand("../scripts/invalid_boot_probe.exs", __DIR__)
  @id "11111111-1111-4111-8111-111111111111"
  @cases [
    :missing,
    :malformed,
    :oversized,
    :config_symlink,
    :unknown_field,
    :wrong_version,
    :invalid_host,
    :insecure_control,
    :ipv6_control,
    :control_path,
    :control_userinfo,
    :relative_socket,
    :long_socket,
    :bad_maximum,
    :bad_openai_origin,
    :bad_agent_switch,
    :bad_release,
    :empty_providers,
    :duplicate_providers,
    :unknown_provider,
    :missing_ca,
    :token_length,
    :token_public,
    :token_symlink,
    :provider_missing,
    :provider_public,
    :provider_symlink,
    :provider_multiline,
    :provider_oversized
  ]

  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{String.t() => json_value()}
  @type mutation ::
          :missing
          | :malformed
          | :oversized
          | :config_symlink
          | :unknown_field
          | :wrong_version
          | :invalid_host
          | :insecure_control
          | :ipv6_control
          | :control_path
          | :control_userinfo
          | :relative_socket
          | :long_socket
          | :bad_maximum
          | :bad_openai_origin
          | :bad_agent_switch
          | :bad_release
          | :empty_providers
          | :duplicate_providers
          | :unknown_provider
          | :missing_ca
          | :token_length
          | :token_public
          | :token_symlink
          | :provider_missing
          | :provider_public
          | :provider_symlink
          | :provider_multiline
          | :provider_oversized
  @type fixture_snapshot :: [{String.t(), atom(), non_neg_integer(), non_neg_integer(), binary()}]
  @type boot_projection :: %{String.t() => String.t() | boolean()}

  # @cc [owner:ghuntley,label:security;verification] generated-ziggy-boot-refusal
  # Invalid configured runtimes MUST reject fresh OTP startup before the named
  # supervisor or reviewed serving/provider worker start entry points are called.
  # Refusal MUST preserve fixture bytes and exclude secrets and fixture paths
  # from diagnostics. Unset configuration MUST remain a separate empty boot.
  property "generated invalid Ziggy configurations refuse fresh OTP startup",
    profile: :ci do
    root = Path.join(System.tmp_dir!(), "k-zb-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    check all(
            order <- shuffle(@cases),
            token <- string(:alphanumeric, length: 80),
            suffix <- string(:alphanumeric, length: 35),
            provider <- member_of(["openai", "anthropic"]),
            maximum <- member_of([0, 100_001, "10", nil]),
            max_runs: 3
          ) do
      for mutation <- order do
        directory = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
        File.mkdir!(directory)
        File.chmod!(directory, 0o700)
        config = configuration(directory, token, suffix)
        path = Path.join(directory, "config.json")
        write_config(path, config)
        assert {:ok, _} = Ziggy.Config.load(path)
        mutate(mutation, path, config, provider, maximum)
        secrets = credential_bytes(config)
        before = snapshot(directory)
        {output, status} = boot(path, config["socket"], config["spool"])
        assert status == 0
        assert projection(output) == expected("rejected", false, true)

        private? =
          not Enum.any?(
            [
              token,
              "synthetic-openai-" <> suffix,
              "synthetic-anthropic-" <> suffix,
              directory | secrets
            ],
            &String.contains?(output, &1)
          )

        assert private?, "boot diagnostics exposed fixture paths or secrets"
        assert snapshot(directory) == before
      end
    end
  end

  test "unset Ziggy configuration starts only an empty supervisor" do
    root = Path.join(System.tmp_dir!(), "k-zu-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {output, status} = boot(nil, Path.join(root, "socket"), Path.join(root, "spool"))
    assert status == 0
    assert projection(output) == expected("started", true, false)
  end

  # @cc [owner:ghuntley,label:security;verification] ziggy-immutable-spool-loader-only
  # Immutable-store spool rejection MUST be checked through the read-only
  # loader, without booting a worker outside the disposable fixture.
  property "generated immutable store spool paths are rejected without boot effects" do
    root = Path.join(System.tmp_dir!(), "k-zs-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    check all(
            suffix <- string(:alphanumeric, min_length: 8, max_length: 32),
            token <- string(:alphanumeric, length: 80),
            max_runs: 20
          ) do
      config = configuration(root, token, suffix)
      path = Path.join(root, "config.json")
      write_config(path, config)
      assert {:ok, _} = Ziggy.Config.load(path)
      write_config(path, Map.put(config, "spool", "/nix/store/" <> suffix <> "-spool"))
      before = snapshot(root)
      rejected? = match?({:error, :invalid_configuration}, Ziggy.Config.load(path))
      assert rejected?, "immutable spool path was accepted by the loader"
      assert snapshot(root) == before
    end
  end

  @spec expected(String.t(), boolean(), boolean()) :: boot_projection()
  defp expected(outcome, started, rejected) do
    %{
      "outcome" => outcome,
      "start_attempted" => started,
      "serving_attempted" => false,
      "rejection_event" => rejected,
      "supervisor" => started,
      "empty_supervisor" => started,
      "spool" => false,
      "catalog" => false,
      "socket" => false,
      "spool_directory" => false
    }
  end

  @spec boot(Path.t() | nil, Path.t(), Path.t()) :: {String.t(), non_neg_integer()}
  defp boot(path, socket, spool) do
    System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", @probe],
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"OVERALLS_BOOT_PROBE", "test"},
        {"OVERALLS_PROBE_ROOT", Path.dirname(socket)},
        {"OVERALLS_PROBE_SOCKET", socket},
        {"OVERALLS_PROBE_SPOOL", spool},
        {"ZIGGY_CONFIG_FILE", path}
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
          Enum.sort(Map.keys(fields)) ==
            Enum.sort(
              ~w(start_attempted serving_attempted rejection_event supervisor empty_supervisor spool catalog socket spool_directory)
            ) and
            Enum.all?(Map.values(fields), &is_boolean/1)

        assert valid?, "invalid boot probe projection"
        value

      _ ->
        flunk("invalid boot probe projection")
    end
  end

  @spec configuration(Path.t(), String.t(), String.t()) :: json_object()
  defp configuration(root, token, suffix) do
    for {name, bytes} <- [
          {"token", token},
          {"openai", "synthetic-openai-" <> suffix},
          {"anthropic", "synthetic-anthropic-" <> suffix},
          {"ca", "synthetic-ca"}
        ] do
      File.write!(Path.join(root, name), bytes)
      File.chmod!(Path.join(root, name), 0o600)
    end

    %{
      "version" => 1,
      "host_id" => @id,
      "control_plane" => "https://control.example.test",
      "ca_file" => Path.join(root, "ca"),
      "credential_file" => Path.join(root, "token"),
      "openai_key_file" => Path.join(root, "openai"),
      "anthropic_key_file" => Path.join(root, "anthropic"),
      "socket" => Path.join(root, "socket"),
      "spool" => Path.join(root, "spool"),
      "max_requests" => 10
    }
  end

  @spec snapshot(Path.t()) :: fixture_snapshot()
  defp snapshot(root) do
    root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn name ->
      path = Path.join(root, name)
      stat = File.lstat!(path)

      bytes =
        case File.read(path) do
          {:ok, bytes} -> bytes
          {:error, :enoent} -> ""
          _ -> flunk("boot changed fixture file types")
        end

      {name, stat.type, stat.mode, stat.links, :crypto.hash(:sha256, bytes)}
    end)
  end

  @spec credential_bytes(json_object()) :: [String.t()]
  defp credential_bytes(config) do
    Enum.flat_map(~w(credential_file openai_key_file anthropic_key_file), fn field ->
      case File.read(config[field]) do
        {:ok, bytes} -> [bytes, String.trim_trailing(bytes, "\n")]
        {:error, :enoent} -> []
      end
    end)
  end

  @spec write_config(Path.t(), json_object()) :: :ok
  defp write_config(path, config) do
    File.write!(path, JSON.encode!(config))
    File.chmod!(path, 0o600)
  end

  @spec mutate(mutation(), Path.t(), json_object(), String.t(), json_value()) :: :ok
  defp mutate(:missing, path, _, _, _), do: File.rm!(path)
  defp mutate(:malformed, path, _, _, _), do: File.write!(path, "{invalid")

  defp mutate(:oversized, path, config, _, _),
    do: File.write!(path, JSON.encode!(config) <> String.duplicate(" ", 16_385))

  defp mutate(:config_symlink, path, _, _, _), do: symlink(path)
  defp mutate(:missing_ca, _, config, _, _), do: File.rm!(config["ca_file"])
  defp mutate(:token_length, _, config, _, _), do: File.write!(config["credential_file"], "short")
  defp mutate(:token_public, _, config, _, _), do: File.chmod!(config["credential_file"], 0o644)
  defp mutate(:token_symlink, _, config, _, _), do: symlink(config["credential_file"])

  defp mutate(kind, _, config, provider, _)
       when kind in [
              :provider_missing,
              :provider_public,
              :provider_symlink,
              :provider_multiline,
              :provider_oversized
            ] do
    path = config[provider <> "_key_file"]

    case kind do
      :provider_missing -> File.rm!(path)
      :provider_public -> File.chmod!(path, 0o644)
      :provider_symlink -> symlink(path)
      :provider_multiline -> File.write!(path, File.read!(path) <> "\nsecond")
      :provider_oversized -> File.write!(path, File.read!(path) <> String.duplicate("x", 8193))
    end
  end

  defp mutate(kind, path, config, _, maximum) do
    {field, value} =
      case kind do
        :unknown_field ->
          {"unexpected", true}

        :wrong_version ->
          {"version", 0}

        :invalid_host ->
          {"host_id", "invalid"}

        :insecure_control ->
          {"control_plane", "http://control.example.test"}

        :ipv6_control ->
          {"control_plane", "https://[::ffff:127.0.0.1]"}

        :control_path ->
          {"control_plane", "https://control.example.test/path"}

        :control_userinfo ->
          {"control_plane", "https://user@control.example.test"}

        :relative_socket ->
          {"socket", "relative.sock"}

        :long_socket ->
          {"socket", config["socket"] <> String.duplicate("s", 108)}

        :bad_maximum ->
          {"max_requests", maximum}

        :bad_openai_origin ->
          {"openai_origin", "http://127.0.0.2:8080"}

        :bad_agent_switch ->
          {"agent_enabled", "true"}

        :bad_release ->
          {"lyra_release", "/tmp/release"}

        :empty_providers ->
          {"enabled_providers", []}

        :duplicate_providers ->
          {"enabled_providers", ["openai", "openai"]}

        :unknown_provider ->
          {"enabled_providers", ["unknown"]}
      end

    write_config(path, Map.put(config, field, value))
  end

  @spec symlink(Path.t()) :: :ok
  defp symlink(path) do
    File.rename!(path, path <> ".target")
    File.ln_s!(path <> ".target", path)
  end
end
