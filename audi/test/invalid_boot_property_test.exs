defmodule Audi.InvalidBootPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  @moduletag :tmp_dir
  # One generated order traverses every one of the 42 role/mutation pairs in
  # fresh OTP VMs. Keep the engine's explicit aggregate budget bounded.
  @moduletag timeout: 600_000
  @id "11111111-1111-4111-8111-111111111111"
  @probe Path.expand("../scripts/invalid_boot_probe.exs", __DIR__)
  @certificate Path.expand("../../marshall/test/fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../../marshall/test/fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../../marshall/test/fixtures/tls/ca.pem", __DIR__)
  @shared [
    :missing,
    :malformed,
    :oversized,
    :writable_config,
    :unknown_field,
    :wrong_version,
    :bad_status,
    :secret_public,
    :secret_symlink,
    :secret_hardlink
  ]
  @cases Enum.flat_map([:gateway, :dns, :private], fn role ->
           extra =
             case role do
               :gateway ->
                 [
                   :invalid_port,
                   :missing_connector,
                   :tls_collision,
                   :host_key_public,
                   :host_key_symlink,
                   :host_key_hardlink
                 ]

               :dns ->
                 [:few_nameservers, :duplicate_nameservers, :gateway_identity]

               :private ->
                 [:missing_key, :missing_roots, :missing_connector]
             end

           Enum.map(@shared ++ extra, &{role, &1})
         end)

  @type role :: :gateway | :dns | :private
  @type mutation ::
          :missing
          | :malformed
          | :oversized
          | :writable_config
          | :unknown_field
          | :wrong_version
          | :bad_status
          | :secret_public
          | :secret_symlink
          | :secret_hardlink
          | :host_key_public
          | :host_key_symlink
          | :host_key_hardlink
          | :invalid_port
          | :missing_connector
          | :tls_collision
          | :few_nameservers
          | :duplicate_nameservers
          | :gateway_identity
          | :missing_key
          | :missing_roots
  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{String.t() => json_value()}
  @type boot_projection :: %{String.t() => String.t() | boolean()}
  @type fixture_snapshot :: [{String.t(), atom(), non_neg_integer(), non_neg_integer(), binary()}]

  # @cc [owner:ghuntley,label:security;verification] generated-audi-role-boot-refusal
  # Invalid gateway, DNS and private-role configurations MUST reject fresh OTP
  # startup before the named supervisor or reviewed listener start entry points
  # are called. Refusal MUST preserve fixture bytes and exclude paths and secrets
  # from diagnostics. Unset configuration MUST remain a separate no-listener boot.
  property "generated invalid Audi role configurations refuse fresh OTP startup",
    profile: :ci,
    test_cases: 1,
    print_blob: false do
    root = Path.join(System.tmp_dir!(), "k-ab-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    order = draw("role_mutation_order", shuffle(@cases))
    suffix = draw("token_suffix", string(:alphanumeric, length: 43))
    invalid_port = draw("invalid_port", member_of([0, 65_536, "22", nil]))

    for {role, mutation} <- order do
      directory = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      token = "audi_service_" <> suffix
      {config, secret} = configuration(role, directory, token)
      path = Path.join(directory, "config.json")
      write_config(path, config)
      assert {:ok, _} = Audi.Config.load(path)
      {:ok, secret_bytes} = File.read(secret)

      key_bytes =
        if role == :gateway,
          do: [File.read!(Path.join(directory, "ssh_host_ed25519_key"))],
          else: []

      mutate(mutation, path, secret, config, token, invalid_port)
      before = snapshot(directory)
      {output, status} = boot(path, config["status_socket"])
      assert status == 0

      assert projection(output) == %{
               "outcome" => "rejected",
               "start_attempted" => false,
               "rejection_event" => true,
               "supervisor" => false,
               "proof_registry" => false,
               "status_socket" => false
             }

      private? =
        not Enum.any?(
          [token, secret_bytes, directory, @certificate, @ca, @key, "-----BEGIN" | key_bytes],
          &String.contains?(output, &1)
        )

      assert private?, "boot diagnostics exposed fixture paths or secrets"
      assert snapshot(directory) == before
    end
  end

  test "unset Audi config starts the proof registry without role listeners", %{tmp_dir: root} do
    {output, 0} = boot(nil, Path.join(root, "status.sock"))

    assert projection(output) == %{
             "outcome" => "started",
             "start_attempted" => true,
             "rejection_event" => false,
             "supervisor" => true,
             "proof_registry" => true,
             "status_socket" => false
           }
  end

  @spec boot(Path.t() | nil, Path.t()) :: {String.t(), non_neg_integer()}
  defp boot(path, status) do
    System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", @probe],
      env: [
        {"MIX_ENV", "test"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"OVERALLS_BOOT_PROBE", "test"},
        {"OVERALLS_PROBE_STATUS", status},
        {"AUDI_CONFIG_FILE", path},
        {"AUDI_SLO_SNAPSHOT", nil}
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
      {:ok,
       %{
         "outcome" => outcome,
         "start_attempted" => attempted,
         "supervisor" => supervisor,
         "proof_registry" => proofs,
         "status_socket" => status,
         "rejection_event" => rejection
       } = value}
      when map_size(value) == 6 and outcome in ["rejected", "started", "other"] and
             is_boolean(rejection) and
             is_boolean(attempted) and is_boolean(supervisor) and is_boolean(proofs) and
             is_boolean(status) ->
        value

      _ ->
        flunk("invalid boot probe projection")
    end
  end

  @spec configuration(role(), Path.t(), String.t()) :: {json_object(), Path.t()}
  defp configuration(:private, root, _token) do
    secret = Path.join(root, "private.key")
    File.cp!(@key, secret)
    File.chmod!(secret, 0o600)

    {%{
       "version" => 1,
       "role" => "private",
       "host_id" => @id,
       "connector_path" => Path.join(root, "connector.sock"),
       "connector_uid" => 1000,
       "ziggy_socket" => Path.join(root, "ziggy.sock"),
       "galileo_socket" => Path.join(root, "galileo.sock"),
       "certificate_file" => @certificate,
       "key_file" => secret,
       "roots_file" => @ca,
       "status_socket" => Path.join(root, "status.sock")
     }, secret}
  end

  defp configuration(role, root, token) when role in [:gateway, :dns] do
    secret = Path.join(root, "credential")
    File.write!(secret, token <> "\n")
    File.chmod!(secret, 0o400)

    common = %{
      "version" => 1,
      "role" => Atom.to_string(role),
      "control_plane" => "https://marshall.example.test",
      "credential_file" => secret,
      "status_socket" => Path.join(root, "status.sock"),
      "bind" => "127.0.0.1",
      "port" => 11_322
    }

    config =
      case role do
        :gateway ->
          key = Path.join(root, "ssh_host_ed25519_key")
          {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])

          Map.merge(common, %{
            "host_id" => @id,
            "connector_path" => Path.join(root, "connector.sock"),
            "connector_uid" => 1000,
            "host_key_dir" => root
          })

        :dns ->
          Map.merge(common, %{
            "zone" => "apps.example.test",
            "mailbox" => "hostmaster.example.test",
            "nameservers" => ["ns1.example.test", "ns2.example.test"]
          })
      end

    {config, secret}
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
        end

      {name, stat.type, stat.mode, stat.links, :crypto.hash(:sha256, bytes)}
    end)
  end

  @spec write_config(Path.t(), json_object()) :: :ok
  defp write_config(path, config) do
    File.write!(path, JSON.encode!(config))
    File.chmod!(path, 0o600)
  end

  @spec mutate(mutation(), Path.t(), Path.t(), json_object(), String.t(), json_value()) :: :ok
  defp mutate(:missing, path, _, _, _, _), do: File.rm!(path)
  defp mutate(:malformed, path, _, _, token, _), do: File.write!(path, "{invalid:" <> token)

  defp mutate(:oversized, path, _, config, _, _),
    do: File.write!(path, JSON.encode!(config) <> String.duplicate(" ", 16_385))

  defp mutate(:writable_config, path, _, _, _, _), do: File.chmod!(path, 0o666)

  defp mutate(:unknown_field, path, _, config, token, _),
    do: write_config(path, Map.put(config, "unexpected", token))

  defp mutate(:wrong_version, path, _, config, _, _),
    do: write_config(path, Map.put(config, "version", 0))

  defp mutate(:bad_status, path, _, config, _, _),
    do:
      write_config(
        path,
        Map.put(config, "status_socket", config["status_socket"] <> "/../bad.sock")
      )

  defp mutate(:secret_public, _, secret, _, _, _), do: File.chmod!(secret, 0o644)

  defp mutate(:secret_symlink, _, secret, _, _, _) do
    File.rename!(secret, secret <> ".target")
    File.ln_s!(secret <> ".target", secret)
  end

  defp mutate(:secret_hardlink, _, secret, _, _, _), do: File.ln!(secret, secret <> ".link")

  defp mutate(kind, path, _secret, config, token, port)
       when kind in [:host_key_public, :host_key_symlink, :host_key_hardlink] do
    key = Path.join(config["host_key_dir"], "ssh_host_ed25519_key")

    target =
      case kind do
        :host_key_public -> :secret_public
        :host_key_symlink -> :secret_symlink
        :host_key_hardlink -> :secret_hardlink
      end

    mutate(target, path, key, config, token, port)
  end

  defp mutate(:invalid_port, path, _, config, _, port),
    do: write_config(path, Map.put(config, "port", port))

  defp mutate(:missing_connector, path, _, config, _, _),
    do: write_config(path, Map.delete(config, "connector_path"))

  defp mutate(:tls_collision, path, _, config, _, _) do
    write_config(
      path,
      Map.put(config, "tls", %{
        "zone" => "apps.example.test",
        "trust_file" => @ca,
        "browser_origin" => "https://public.example.test",
        "http_port" => config["port"],
        "https_port" => 11_443
      })
    )
  end

  defp mutate(:few_nameservers, path, _, config, _, _),
    do: write_config(path, Map.put(config, "nameservers", ["ns1.example.test"]))

  defp mutate(:duplicate_nameservers, path, _, config, _, _),
    do:
      write_config(path, Map.put(config, "nameservers", ["ns1.example.test", "ns1.example.test"]))

  defp mutate(:gateway_identity, path, _, config, _, _),
    do: write_config(path, Map.put(config, "host_id", @id))

  defp mutate(:missing_key, path, _, config, _, _),
    do: write_config(path, Map.delete(config, "key_file"))

  defp mutate(:missing_roots, path, _, config, _, _),
    do: write_config(path, Map.delete(config, "roots_file"))
end
