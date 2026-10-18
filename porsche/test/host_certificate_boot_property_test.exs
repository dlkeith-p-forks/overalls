defmodule Porsche.HostCertificateBootPropertyTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias OverallsProtocol.{SSHHostCertificate, SSHKey}
  # All 18 independent mutations must boot; each subprocess has a 30-second bound.
  # The finite aggregate budget includes shared-host and positive-control headroom.
  @moduletag timeout: 900_000
  @probe Path.expand("../scripts/host_certificate_boot_probe.exs", __DIR__)
  @cases [
    :missing,
    :empty,
    :malformed,
    :base64,
    :truncated,
    :signature,
    :nonce,
    :other_leaf,
    :other_private,
    :malformed_private,
    :expired,
    :future,
    :multiple_principals,
    :user_type,
    :trailing,
    :critical,
    :extensions,
    :no_principals
  ]
  @flags ~w(supervisor_attempted listener_attempted status_attempted observability_attempted daemon_attempted supervisor base_present configured_children listener socket ready ssh_banner)
  @type mutation ::
          :missing
          | :empty
          | :malformed
          | :base64
          | :truncated
          | :signature
          | :nonce
          | :other_leaf
          | :other_private
          | :malformed_private
          | :expired
          | :future
          | :multiple_principals
          | :user_type
          | :trailing
          | :critical
          | :extensions
          | :no_principals
  @type template :: %{
          private: binary(),
          other_private: binary(),
          key: String.t(),
          other_key: String.t(),
          ca: String.t(),
          seed: binary(),
          now: non_neg_integer()
        }
  @type fixture :: %{
          root: Path.t(),
          config: Path.t(),
          keys: Path.t(),
          cert: Path.t(),
          private: Path.t(),
          socket: Path.t(),
          token: String.t()
        }
  @type projection :: %{String.t() => boolean() | String.t()}
  @type snapshot_entry ::
          {String.t(), :regular | :directory | :symlink, non_neg_integer(), pos_integer(),
           non_neg_integer(), non_neg_integer(), binary()}

  setup do
    root = private_directory("k-hc-")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, host} = generate_key(root, "host")
    {:ok, other} = generate_key(root, "other")
    {ca_raw, seed} = :crypto.generate_key(:eddsa, :ed25519)
    ca = "ssh-ed25519 " <> Base.encode64(ssh_string("ssh-ed25519") <> ssh_string(ca_raw))
    {:ok, %{public_key: ca}} = SSHKey.parse(ca)

    template = %{
      private: File.read!(Path.join(root, "host")),
      other_private: File.read!(Path.join(root, "other")),
      key: host.public_key,
      other_key: other.public_key,
      ca: ca,
      seed: seed,
      now: System.system_time(:second)
    }

    %{root: root, template: template}
  end

  # @cc [owner:ghuntley,label:security;verification] certificate-boot-oracle
  # The exhaustive matrix MUST cover each mutation of a real-loader and Proof-accepted
  # baseline. Refusal MUST occur in the first listener child, before ssh.daemon,
  # status or observability, with no surviving service state and unchanged owned
  # fixtures. Original/mutated private material and paths MUST stay out of output.
  # Each mutation boots an independent VM from the same accepted baseline;
  # repeating random permutations cannot explore additional histories.
  test "invalid host certificates refuse Porsche startup before the SSH daemon", context do
    for kind <- @cases do
      f = fixture(context.root, context.template)
      assert {:ok, _} = Porsche.Config.load(f.config)
      assert {:ok, _} = host_certificate(f)
      original = materials(f)
      mutate(f, context.template, kind)
      assert {:ok, _} = Porsche.Config.load(f.config)
      before = snapshot(f.root)
      sensitive = original ++ materials(f) ++ [context.template.seed, f.token, f.root]
      {projection, output} = boot(f, "refusal")
      assert projection == expected(false), "host-certificate case #{kind}"
      assert snapshot(f.root) == before

      Enum.each(sensitive, fn material ->
        if byte_size(material) >= 24, do: refute(String.contains?(output, material))
      end)
    end
  end

  test "valid disposable host certificate starts the real loopback Porsche daemon", context do
    f = fixture(context.root, context.template)
    {:ok, reservation} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(reservation)
    :ok = :gen_tcp.close(reservation)
    {:ok, config} = f.config |> File.read!() |> JSON.decode()
    File.write!(f.config, JSON.encode!(Map.put(config, "port", port)))
    assert {:ok, _} = Porsche.Config.load(f.config)
    assert {:ok, _} = host_certificate(f)
    before = snapshot(f.root)
    {projection, output} = boot(f, "positive")
    assert projection == expected(true)
    assert snapshot(f.root) == before

    Enum.each(materials(f) ++ [context.template.seed, f.token, f.root], fn material ->
      if byte_size(material) >= 24, do: refute(String.contains?(output, material))
    end)
  end

  @spec expected(boolean()) :: projection()
  defp expected(started) do
    Map.new(@flags, fn field ->
      {field, started or field in ["supervisor_attempted", "listener_attempted"]}
    end)
    |> Map.put("outcome", if(started, do: "started", else: "rejected"))
  end

  # @cc [owner:ghuntley,label:verification] fresh-boot-operation-deadline
  # Each probe MUST run in a fresh VM with the complete startup oracle. A boot
  # exceeding 30 seconds MUST fail; its process group gets at most five seconds
  # to terminate before forced cleanup, independently of the aggregate budget.
  @spec boot(fixture(), String.t()) :: {projection(), String.t()}
  defp boot(f, mode) do
    {output, status} =
      System.cmd(
        "timeout",
        [
          "--signal=TERM",
          "--kill-after=5s",
          "30s",
          "mix",
          "run",
          "--no-start",
          "--no-compile",
          "--no-deps-check",
          @probe
        ],
        env: [
          {"MIX_ENV", "test"},
          {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
          {"OVERALLS_BOOT_PROBE", "test"},
          {"OVERALLS_PROBE_ROOT", f.root},
          {"OVERALLS_PROBE_SOCKET", f.socket},
          {"OVERALLS_PROBE_MODE", mode},
          {"PORSCHE_CONFIG_FILE", f.config},
          {"PORSCHE_SLO_SNAPSHOT", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "host-certificate probe exited unexpectedly"
    lines = for "CERT_BOOT_PROBE:" <> line <- String.split(output, "\n"), do: line

    decoded =
      case lines do
        [line] -> JSON.decode(line)
        _ -> :invalid
      end

    case decoded do
      {:ok, %{"outcome" => outcome} = value}
      when map_size(value) == 13 and outcome in ["started", "rejected", "other"] ->
        fields = Map.delete(value, "outcome")
        assert Enum.sort(Map.keys(fields)) == Enum.sort(@flags)
        assert Enum.all?(Map.values(fields), &is_boolean/1)
        {value, output}

      _ ->
        flunk("invalid host-certificate projection")
    end
  end

  @spec fixture(Path.t(), template()) :: fixture()
  defp fixture(parent, template) do
    root = private_directory("case-", parent)
    keys = Path.join(root, "keys")
    File.mkdir!(keys)
    File.chmod!(keys, 0o700)
    status = Path.join(root, "status")
    File.mkdir!(status)
    File.chmod!(status, 0o700)
    token = "porsche_gateway_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    credential = Path.join(root, "credential")
    File.write!(credential, token)
    File.chmod!(credential, 0o600)
    private = Path.join(keys, "ssh_host_ed25519_key")
    File.write!(private, template.private)
    File.chmod!(private, 0o600)
    cert = Path.join(keys, "ssh_host_ed25519_key-cert.pub")

    File.write!(
      cert,
      issue(
        template,
        template.key,
        ["porsche.example.test"],
        template.now - 300,
        template.now + 3600
      )
    )

    File.chmod!(cert, 0o644)
    socket = Path.join(status, "sock")
    config = Path.join(root, "config.json")

    File.write!(
      config,
      JSON.encode!(%{
        "version" => 1,
        "control_plane" => "https://control.example.test",
        "public_origin" => "https://porsche.example.test",
        "credential_file" => credential,
        "host_key_dir" => keys,
        "bind" => "127.0.0.1",
        "port" => 22222,
        "status_socket" => socket
      })
    )

    File.chmod!(config, 0o600)

    %{
      root: root,
      config: config,
      keys: keys,
      cert: cert,
      private: private,
      socket: socket,
      token: token
    }
  end

  @spec host_certificate(fixture()) :: {:ok, binary()} | {:error, atom()}
  defp host_certificate(f) do
    Porsche.SSH.Proof.host_certificate(:"ssh-ed25519-cert-v01@openssh.com",
      system_dir: String.to_charlist(f.keys)
    )
  end

  @spec issue(template(), String.t(), [String.t()], non_neg_integer(), pos_integer()) ::
          String.t()
  defp issue(template, key, names, after_time, before_time) do
    {:ok, certificate} =
      SSHHostCertificate.issue(
        key,
        template.ca,
        template.seed,
        names,
        7,
        "private-fixture-certificate",
        after_time,
        before_time
      )

    certificate
  end

  @spec mutate(fixture(), template(), mutation()) :: :ok
  defp mutate(f, t, kind) do
    {:ok, certificate} = SSHHostCertificate.parse(File.read!(f.cert))

    case kind do
      :missing ->
        File.rm!(f.cert)

      :empty ->
        File.write!(f.cert, "")

      :malformed ->
        File.write!(
          f.cert,
          "private_invalid_certificate_" <>
            Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        )

      :base64 ->
        File.write!(f.cert, SSHHostCertificate.algorithm() <> " invalid!base64")

      :truncated ->
        write_blob(f, binary_part(certificate.blob, 0, byte_size(certificate.blob) - 9))

      :signature ->
        write_blob(f, flip(certificate.blob, byte_size(certificate.blob) - 1))

      :nonce ->
        write_blob(f, flip(certificate.blob, 8 + byte_size(SSHHostCertificate.algorithm())))

      :other_leaf ->
        File.write!(
          f.cert,
          issue(t, t.other_key, ["porsche.example.test"], t.now - 300, t.now + 3600)
        )

      :other_private ->
        File.write!(f.private, t.other_private)

      :malformed_private ->
        File.write!(
          f.private,
          "private_invalid_key_" <>
            Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        )

      :expired ->
        File.write!(f.cert, issue(t, t.key, ["porsche.example.test"], t.now - 3600, t.now - 600))

      :future ->
        File.write!(f.cert, issue(t, t.key, ["porsche.example.test"], t.now + 3600, t.now + 7200))

      :multiple_principals ->
        File.write!(
          f.cert,
          issue(
            t,
            t.key,
            ["porsche.example.test", "other.example.test"],
            t.now - 300,
            t.now + 3600
          )
        )

      :user_type ->
        write_signed(f, change_type(certificate.signed), t.seed)

      :trailing ->
        write_blob(f, certificate.blob <> <<0>>)

      kind when kind in [:critical, :extensions, :no_principals] ->
        {head, names, clock, critical, extensions, tail} = parts(certificate.signed)
        option = ssh_string("source-address") <> ssh_string(ssh_string("127.0.0.1"))
        names = if kind == :no_principals, do: "", else: names
        critical = if kind == :critical, do: option, else: critical

        extensions =
          if kind == :extensions, do: ssh_string("permit-pty") <> ssh_string(""), else: extensions

        signed =
          head <>
            ssh_string(names) <> clock <> ssh_string(critical) <> ssh_string(extensions) <> tail

        write_signed(f, signed, t.seed)
    end

    :ok
  end

  @spec write_blob(fixture(), binary()) :: :ok
  defp write_blob(f, blob),
    do: File.write!(f.cert, SSHHostCertificate.algorithm() <> " " <> Base.encode64(blob))

  @spec write_signed(fixture(), binary(), binary()) :: :ok
  defp write_signed(f, signed, seed) do
    signature = :crypto.sign(:eddsa, :none, signed, [seed, :ed25519])
    write_blob(f, signed <> ssh_string(ssh_string("ssh-ed25519") <> ssh_string(signature)))
  end

  @spec parts(binary()) :: {binary(), binary(), binary(), binary(), binary(), binary()}
  defp parts(signed) do
    {_, rest} = take_string(signed)
    {_, rest} = take_string(rest)
    {_, <<_serial::64, _type::32, rest::binary>>} = take_string(rest)
    {_, rest} = take_string(rest)
    head = binary_part(signed, 0, byte_size(signed) - byte_size(rest))
    {names, <<clock::binary-size(16), rest::binary>>} = take_string(rest)
    {critical, rest} = take_string(rest)
    {extensions, tail} = take_string(rest)
    {head, names, clock, critical, extensions, tail}
  end

  @spec change_type(binary()) :: binary()
  defp change_type(signed) do
    {_, rest} = take_string(signed)
    {_, rest} = take_string(rest)
    {_, body} = take_string(rest)
    <<serial::64, 2::32, tail::binary>> = body
    prefix = binary_part(signed, 0, byte_size(signed) - byte_size(body))
    prefix <> <<serial::64, 1::32>> <> tail
  end

  @spec take_string(binary()) :: {binary(), binary()}
  defp take_string(<<length::32, value::binary-size(length), rest::binary>>), do: {value, rest}
  @spec ssh_string(binary()) :: binary()
  defp ssh_string(value), do: <<byte_size(value)::32, value::binary>>
  @spec flip(binary(), non_neg_integer()) :: binary()
  defp flip(blob, index) do
    <<head::binary-size(^index), byte, tail::binary>> = blob
    head <> <<bxor(byte, 1)>> <> tail
  end

  @spec generate_key(Path.t(), String.t()) :: {:ok, SSHKey.t()}
  defp generate_key(root, name) do
    {_, status} =
      System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", Path.join(root, name)],
        stderr_to_stdout: true
      )

    assert status == 0, "disposable key generation failed"
    {:ok, key} = SSHKey.parse(File.read!(Path.join(root, name <> ".pub")))
    {:ok, key}
  end

  @spec private_directory(String.t(), Path.t()) :: Path.t()
  defp private_directory(prefix, parent \\ System.tmp_dir!()) do
    root = Path.join(parent, prefix <> Base.encode16(:crypto.strong_rand_bytes(6)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  @spec materials(fixture()) :: [binary()]
  defp materials(f) do
    [f.config, f.private, f.cert]
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, bytes} -> [bytes]
        {:error, :enoent} -> []
      end
    end)
  end

  @spec snapshot(Path.t()) :: [snapshot_entry()]
  defp snapshot(root) do
    stat = File.lstat!(root)

    [
      {".", stat.type, stat.mode, stat.links, stat.uid, stat.gid, :crypto.hash(:sha256, "")}
      | snapshot_entries(root, "")
    ]
  end

  @spec snapshot_entries(Path.t(), String.t()) :: [snapshot_entry()]
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
          _ -> flunk("host-certificate boot changed fixture types")
        end

      [
        {child, stat.type, stat.mode, stat.links, stat.uid, stat.gid,
         :crypto.hash(:sha256, bytes)}
        | descendants
      ]
    end)
  end
end
