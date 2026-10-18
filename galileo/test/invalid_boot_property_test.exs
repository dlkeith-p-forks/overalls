defmodule Galileo.InvalidBootPropertyTest do
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
           :non_object,
           :unknown_field,
           :wrong_version,
           :invalid_host,
           :insecure_control,
           :control_path,
           :control_userinfo,
           :control_query,
           :control_fragment,
           :relative_socket,
           :long_socket,
           :noncanonical_socket,
           :missing_ca,
           :credential_missing,
           :credential_empty,
           :token_length,
           :token_public,
           :token_symlink,
           :token_multiline,
           :token_oversized
         ] ++
           Enum.map(
             ~w(version host_id control_plane ca_file credential_file socket),
             &{:missing_field, &1}
           )

  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{String.t() => json_value()}
  @type mutation ::
          :missing
          | :malformed
          | :oversized
          | :config_symlink
          | :non_object
          | :unknown_field
          | :wrong_version
          | :invalid_host
          | :insecure_control
          | :control_path
          | :control_userinfo
          | :control_query
          | :control_fragment
          | :relative_socket
          | :long_socket
          | :noncanonical_socket
          | :missing_ca
          | :credential_missing
          | :credential_empty
          | :token_length
          | :token_public
          | :token_symlink
          | :token_multiline
          | :token_oversized
          | {:missing_field, String.t()}
  @type fixture_snapshot :: [{String.t(), atom(), non_neg_integer(), non_neg_integer(), binary()}]
  @type boot_projection :: %{String.t() => String.t() | boolean()}

  # @cc [owner:ghuntley,label:security;verification] generated-galileo-boot-refusal
  # Invalid configured runtimes MUST reject fresh OTP startup before the named
  # supervisor or reviewed Finch/Bandit/SLO startup entry points are called.
  # Refusal MUST preserve fixture bytes and exclude credentials and fixture paths
  # from diagnostics. Unset configuration MUST remain a separate empty boot.
  property "generated invalid Galileo configurations refuse fresh OTP startup",
    profile: :ci do
    root = private_directory("k-gb-")
    on_exit(fn -> File.rm_rf!(root) end)

    check all(
            order <- shuffle(@cases),
            token <- string(:alphanumeric, length: 80),
            invalid_length <- member_of([79, 81, 8192]),
            max_runs: 3
          ) do
      for mutation <- order do
        directory = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
        File.mkdir!(directory)
        File.chmod!(directory, 0o700)
        config = configuration(directory, token)
        path = Path.join(directory, "config.json")
        write_config(path, config)
        assert {:ok, _} = Galileo.Config.load(path)
        mutate(mutation, path, config, invalid_length)
        credentials = credential_bytes(config["credential_file"])
        before = snapshot(directory)
        {output, status} = boot(path, config["socket"])
        assert status == 0
        assert projection(output) == expected("rejected", false, true)

        private? =
          not Enum.any?([token, directory | credentials], &String.contains?(output, &1))

        assert private?, "boot diagnostics exposed fixture paths or credentials"
        assert snapshot(directory) == before
      end
    end
  end

  test "unset Galileo configuration starts only an empty supervisor" do
    root = private_directory("k-gu-")
    on_exit(fn -> File.rm_rf!(root) end)
    {output, status} = boot(nil, Path.join(root, "socket"))
    assert status == 0
    assert projection(output) == expected("started", true, false)
  end

  # @cc [owner:ghuntley,label:security;verification] galileo-immutable-socket-loader-only
  # Immutable-store socket rejection MUST be checked through the read-only
  # loader, without booting a listener outside the disposable fixture.
  property "generated immutable store socket paths are rejected without boot effects",
    profile: :ci do
    root = private_directory("k-gs-")
    on_exit(fn -> File.rm_rf!(root) end)

    check all(
            suffix <- string(:alphanumeric, min_length: 8, max_length: 32),
            token <- string(:alphanumeric, length: 80),
            max_runs: 20
          ) do
      config = configuration(root, token)
      path = Path.join(root, "config.json")
      write_config(path, config)
      assert {:ok, _} = Galileo.Config.load(path)
      write_config(path, Map.put(config, "socket", "/nix/store/" <> suffix <> ".sock"))
      before = snapshot(root)
      rejected? = match?({:error, :invalid_configuration}, Galileo.Config.load(path))
      assert rejected?, "immutable socket path was accepted by the loader"
      assert snapshot(root) == before
    end
  end

  @spec private_directory(String.t()) :: Path.t()
  defp private_directory(prefix) do
    root = Path.join(System.tmp_dir!(), prefix <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
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
      "finch" => false,
      "slo" => false,
      "socket" => false
    }
  end

  @spec boot(Path.t() | nil, Path.t()) :: {String.t(), non_neg_integer()}
  defp boot(path, socket) do
    System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", @probe],
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"OVERALLS_BOOT_PROBE", "test"},
        {"OVERALLS_PROBE_ROOT", Path.dirname(socket)},
        {"OVERALLS_PROBE_SOCKET", socket},
        {"GALILEO_CONFIG_FILE", path}
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
      when map_size(value) == 9 and outcome in ["rejected", "started", "other"] ->
        fields = Map.delete(value, "outcome")

        valid? =
          Enum.sort(Map.keys(fields)) ==
            Enum.sort(
              ~w(start_attempted serving_attempted rejection_event supervisor empty_supervisor finch slo socket)
            ) and
            Enum.all?(Map.values(fields), &is_boolean/1)

        assert valid?, "invalid boot probe projection"
        value

      _ ->
        flunk("invalid boot probe projection")
    end
  end

  @spec configuration(Path.t(), String.t()) :: json_object()
  defp configuration(root, token) do
    File.write!(Path.join(root, "token"), token)
    File.chmod!(Path.join(root, "token"), 0o600)
    File.write!(Path.join(root, "ca"), "synthetic-ca")

    %{
      "version" => 1,
      "host_id" => @id,
      "control_plane" => "https://control.example.test",
      "ca_file" => Path.join(root, "ca"),
      "credential_file" => Path.join(root, "token"),
      "socket" => Path.join(root, "socket")
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

  @spec credential_bytes(Path.t()) :: [String.t()]
  defp credential_bytes(path) do
    case File.read(path) do
      {:ok, ""} -> []
      {:ok, bytes} -> [bytes, String.trim_trailing(bytes, "\n")]
      {:error, :enoent} -> []
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
  defp mutate(:non_object, path, _, _), do: File.write!(path, "[]")

  defp mutate(:oversized, path, config, _),
    do: File.write!(path, JSON.encode!(config) <> String.duplicate(" ", 16_385))

  defp mutate(:config_symlink, path, _, _), do: symlink(path)
  defp mutate(:missing_ca, _, config, _), do: File.rm!(config["ca_file"])
  defp mutate(:credential_missing, _, config, _), do: File.rm!(config["credential_file"])
  defp mutate(:credential_empty, _, config, _), do: File.write!(config["credential_file"], "")
  defp mutate(:token_public, _, config, _), do: File.chmod!(config["credential_file"], 0o644)
  defp mutate(:token_symlink, _, config, _), do: symlink(config["credential_file"])

  defp mutate(:token_length, _, config, length) do
    path = config["credential_file"]
    File.write!(path, String.slice(File.read!(path) <> String.duplicate("x", 8192), 0, length))
  end

  defp mutate(:token_multiline, _, config, _) do
    path = config["credential_file"]
    File.write!(path, File.read!(path) <> "\nsecond")
  end

  defp mutate(:token_oversized, _, config, _) do
    path = config["credential_file"]
    File.write!(path, File.read!(path) <> String.duplicate("x", 8193))
  end

  defp mutate({:missing_field, field}, path, config, _),
    do: write_config(path, Map.delete(config, field))

  defp mutate(kind, path, config, _) do
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

        :control_path ->
          {"control_plane", "https://control.example.test/path"}

        :control_userinfo ->
          {"control_plane", "https://user@control.example.test"}

        :control_query ->
          {"control_plane", "https://control.example.test?query"}

        :control_fragment ->
          {"control_plane", "https://control.example.test#fragment"}

        :relative_socket ->
          {"socket", "relative.sock"}

        :long_socket ->
          {"socket", config["socket"] <> String.duplicate("s", 108)}

        :noncanonical_socket ->
          {"socket", config["socket"] <> "/../bad.sock"}
      end

    write_config(path, Map.put(config, field, value))
  end

  @spec symlink(Path.t()) :: :ok
  defp symlink(path) do
    File.rename!(path, path <> ".target")
    File.ln_s!(path <> ".target", path)
  end
end
