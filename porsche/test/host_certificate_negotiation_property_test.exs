defmodule Porsche.HostCertificateNegotiationPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @algorithm "ssh-ed25519-cert-v01@openssh.com"
  @type trust_case :: :trusted | :foreign_ca | :foreign_name | :absent
  @type fixture :: %{directory: Path.t(), port: non_neg_integer(), backend: pid()}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "porsche-trust-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    for name <- ["ssh_host_ed25519_key", "id_ed25519", "ca", "foreign_ca"] do
      {_, 0} =
        System.cmd("ssh-keygen", [
          "-q",
          "-t",
          "ed25519",
          "-N",
          "",
          "-f",
          Path.join(directory, name)
        ])
    end

    {_, 0} =
      System.cmd("ssh-keygen", [
        "-q",
        "-s",
        Path.join(directory, "ca"),
        "-I",
        "disposable",
        "-h",
        "-n",
        "management.test",
        "-V",
        "-1m:+1h",
        Path.join(directory, "ssh_host_ed25519_key.pub")
      ])

    assert {:ok, _} =
             Porsche.SSH.Proof.host_certificate(:"ssh-ed25519-cert-v01@openssh.com",
               system_dir: String.to_charlist(directory)
             )

    backend = start_supervised!({Agent, fn -> [] end})

    {:ok, client} =
      Porsche.Client.new(
        "https://marshall.test",
        "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
      )

    owner = self()

    listener =
      start_supervised!(
        {Porsche.Listener,
         [
           port: 0,
           bind: {127, 0, 0, 1},
           host_key_dir: directory,
           client: client,
           public_origin: "https://marshall.test",
           request: fn _, route, message, _ ->
             Agent.update(backend, &[{route, message} | &1])
             if route == "close", do: send(owner, :session_closed)

             if route == "sessions" do
               {:ok, key} = OverallsProtocol.SSHKey.parse(message["public_key"])
               {:ok, response} = reply(route)
               {:ok, Map.put(response, "fingerprint", key.fingerprint)}
             else
               reply(route)
             end
           end
         ]}
      )

    %{directory: directory, port: Porsche.Listener.port(listener), backend: backend}
  end

  # @cc [owner:ghuntley,label:security;verification] openssh-client-ca-refusal
  # Real OpenSSH with strict certificate-only host verification MUST reject absent
  # trust, a foreign CA and a mismatched hostname before Porsche submits a session.
  # A trusted matching certificate MUST reach signed user-key proof with the real
  # Proof callback. The scripted pending reply MUST NOT establish account authority.
  property "strict OpenSSH certificate trust gates real signed-key session submission", fixture do
    check all(cases <- shuffle([:trusted, :foreign_ca, :foreign_name, :absent]), max_runs: 3) do
      for kind <- cases do
        Agent.update(fixture.backend, fn _ -> [] end)
        {output, status} = connect(fixture, kind)
        calls = Agent.get(fixture.backend, & &1)

        if kind == :trusted do
          assert_receive :session_closed, 5000
          assert status == 3
          assert output =~ "approval_required"
          assert [{"sessions", message}] = Enum.filter(calls, &(elem(&1, 0) == "sessions"))

          assert {:ok, expected} =
                   OverallsProtocol.SSHKey.parse(
                     File.read!(Path.join(fixture.directory, "id_ed25519.pub"))
                   )

          assert message["public_key"] == expected.public_key
          refute Enum.any?(calls, &(elem(&1, 0) == "commands"))
        else
          assert status == 255

          assert output =~ "Host key verification failed" or
                   output =~ "Couldn't drop certificate: unknown or unsupported key type"

          assert calls == []
        end
      end
    end
  end

  @spec connect(fixture(), trust_case()) :: {String.t(), integer()}
  defp connect(fixture, kind) do
    ca = if kind == :foreign_ca, do: "foreign_ca", else: "ca"
    authority = File.read!(Path.join(fixture.directory, ca <> ".pub")) |> String.trim()
    name = if kind == :foreign_name, do: "other.test", else: "management.test"
    known = Path.join(fixture.directory, "known_hosts")

    File.write!(
      known,
      if(kind == :absent, do: "", else: "@cert-authority #{name} #{authority}\n")
    )

    System.cmd(
      "ssh",
      [
        "-F",
        "/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=#{known}",
        "-o",
        "HostKeyAlias=#{name}",
        "-o",
        "HostKeyAlgorithms=#{@algorithm}",
        "-o",
        "ConnectTimeout=5",
        "-p",
        Integer.to_string(fixture.port),
        "-i",
        Path.join(fixture.directory, "id_ed25519"),
        "ignored@127.0.0.1",
        "whoami --json"
      ],
      stderr_to_stdout: true
    )
  end

  @spec reply(String.t()) ::
          {:ok, %{required(String.t()) => String.t()}} | {:error, :unexpected_route}
  defp reply("sessions"),
    do:
      {:ok,
       %{
         "session_id" => "11111111-1111-4111-8111-111111111111",
         "session_token" => "porsche_session_" <> Base.url_encode64(<<0::256>>, padding: false),
         "expires_at" => "2099-01-01T00:00:00Z",
         "status" => "pending",
         "fingerprint" => "SHA256:disposable",
         "approval_path" =>
           "/ssh/approve/porsche_approval_" <> Base.url_encode64(<<0::256>>, padding: false)
       }}

  defp reply("session"),
    do:
      {:ok,
       %{
         "session_id" => "11111111-1111-4111-8111-111111111111",
         "expires_at" => "2099-01-01T00:00:00Z",
         "status" => "pending"
       }}

  defp reply("close"),
    do: {:ok, %{"session_id" => "11111111-1111-4111-8111-111111111111", "closed" => true}}

  defp reply(_), do: {:error, :unexpected_route}
end
