defmodule Lilly.Transfer.SSHTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Lilly.Transfer.{Key, SSH}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)

    request = %{
      host_id: Lilly.UUID.generate(),
      relocation_id: Lilly.UUID.generate(),
      placement_id: Lilly.UUID.generate(),
      source_host_id: Lilly.UUID.generate()
    }

    {:ok, public} = Key.ensure(root, request.host_id, request.relocation_id, request.placement_id)
    endpoint = %{"address" => "127.0.0.1", "port" => 2222, "host_key" => public}
    %{root: root, request: request, endpoint: endpoint}
  end

  defp connection(c),
    do:
      Key.connection(
        c.root,
        c.request.host_id,
        c.request.relocation_id,
        c.request.placement_id,
        c.request.source_host_id,
        c.endpoint
      )

  test "probe command preserves the pinned transport and rejects noncanonical challenges", c do
    {:ok, files} = connection(c)
    challenge = Lilly.UUID.generate()
    assert {:ok, {ssh, args}} = SSH.command(c.endpoint, c.request, files)
    assert {:ok, {^ssh, probe}} = SSH.probe_command(c.endpoint, c.request, files, challenge)
    assert Enum.drop(args, -2) == Enum.drop(probe, -3)
    assert Enum.take(probe, -3) == ["lilly-probe-v3", c.request.relocation_id, challenge]

    for bad <- [nil, "", challenge <> "\n", challenge <> ";id"] do
      assert {:error, _} = SSH.probe_command(c.endpoint, c.request, files, bad)
    end

    assert {:error, _} =
             SSH.probe_command(c.endpoint, Map.put(c.request, :kind, :full), files, challenge)

    assert {:error, _} = SSH.probe(c.root, c.request, c.endpoint, challenge, 30_001)

    assert :ok =
             Key.retire(
               c.root,
               c.request.host_id,
               c.request.relocation_id,
               c.request.placement_id
             )

    assert {:error, _} = SSH.probe(c.root, c.request, c.endpoint, challenge, 1000)
  end

  test "resume request preserves transport restrictions and rejects shell syntax", c do
    {:ok, files} = connection(c)
    token = "1-a-10-aabb"
    assert {:ok, {ssh, normal}} = SSH.command(c.endpoint, c.request, files)
    assert {:ok, {^ssh, resumed}} = SSH.resume_command(c.endpoint, c.request, files, token)
    assert Enum.drop(normal, -2) == Enum.drop(resumed, -3)

    assert {:ok, %{resume_token: ^token}} =
             resumed |> Enum.take(-3) |> Enum.join(" ") |> Lilly.Transfer.ExportRequest.parse()

    for bad <- [nil, token <> ";id", token <> "\n", String.duplicate("a", 8193)] do
      assert {:error, :invalid_ssh_transfer} =
               SSH.resume_command(c.endpoint, c.request, files, bad)
    end
  end

  test "ready key and source pin survive retries but refuse rebinding and retirement", c do
    assert {:ok, files} = connection(c)
    assert {:ok, ^files} = connection(c)

    assert File.read!(files.known_hosts) ==
             "lilly-#{c.request.source_host_id} #{c.endpoint["host_key"]}\n"

    assert Bitwise.band(File.stat!(files.known_hosts).mode, 0o777) == 0o600
    assert {:error, _} = connection(%{c | endpoint: %{c.endpoint | "port" => 22}})

    assert {:error, _} =
             connection(%{c | request: %{c.request | source_host_id: Lilly.UUID.generate()}})

    File.rm!(files.known_hosts)
    assert {:error, _} = connection(%{c | endpoint: %{c.endpoint | "port" => 22}})
    assert {:ok, ^files} = connection(c)

    assert :ok =
             Key.retire(
               c.root,
               c.request.host_id,
               c.request.relocation_id,
               c.request.placement_id
             )

    assert {:error, _} = connection(c)
    refute File.exists?(files.identity_file)
  end

  test "missing private identity or unbound known-hosts data cannot be reconstructed", c do
    assert {:ok, files} = connection(c)
    directory = Path.dirname(files.identity_file)
    File.rm!(Path.join(directory, "key.json"))
    assert {:error, _} = connection(c)
    File.rm!(files.known_hosts)
    File.rm!(files.identity_file)
    assert {:error, _} = connection(c)
    refute File.exists?(files.identity_file)
  end

  test "pull and probe failures emit closed reasons without command arguments", c do
    :ok =
      Key.retire(c.root, c.request.host_id, c.request.relocation_id, c.request.placement_id)

    output =
      capture_log([metadata: [:event, :reason, :relocation_id]], fn ->
        assert {:error, :invalid_transfer_connection} =
                 SSH.pull(c.root, c.request, c.endpoint, {"cat", []}, 1000)

        assert {:error, :invalid_transfer_connection} =
                 SSH.probe(c.root, c.request, c.endpoint, Lilly.UUID.generate(), 1000)
      end)

    assert output =~ "lilly.ssh_pull_failed"
    assert output =~ "lilly.ssh_probe_failed"
    assert output =~ "invalid_transfer_connection"
    assert output =~ c.request.relocation_id
    refute output =~ "lilly-export-v3"
    refute output =~ "lilly-probe-v3"
    refute output =~ c.endpoint["address"]
    refute output =~ c.endpoint["host_key"]
  end

  test "real OpenSSH effective configuration disables ambient authentication and forwarding", c do
    {:ok, files} = connection(c)
    assert {:ok, {ssh, args}} = SSH.command(c.endpoint, c.request, files)
    {output, 0} = System.cmd(ssh, ["-G" | args], stderr_to_stdout: true)

    configuration =
      Map.new(String.split(output, "\n", trim: true), fn line ->
        [key, value] = String.split(line, " ", parts: 2)
        {key, value}
      end)

    for {key, value} <- %{
          "addressfamily" => "inet",
          "user" => "lilly-transfer",
          "identityagent" => "none",
          "stricthostkeychecking" => "true",
          "identitiesonly" => "yes",
          "forwardagent" => "no",
          "forwardx11" => "no",
          "controlmaster" => "false",
          "batchmode" => "yes",
          "preferredauthentications" => "publickey",
          "hostkeyalgorithms" => "ssh-ed25519",
          "userknownhostsfile" => files.known_hosts,
          "globalknownhostsfile" => "/dev/null",
          "identityfile" => files.identity_file
        } do
      assert configuration[key] == value
    end

    assert Enum.take(args, -2) == ["lilly-export-v4", c.request.relocation_id]

    assert {:ok, parsed} =
             args |> Enum.take(-2) |> Enum.join(" ") |> Lilly.Transfer.ExportRequest.parse()

    assert parsed == %{relocation_id: c.request.relocation_id}
  end

  test "paths with SSH expansion syntax and peer command fields are rejected", c do
    {:ok, files} = connection(c)

    for path <- ["/tmp/%h/key", "/tmp/${HOME}/key", "/tmp/a b/key", "relative"] do
      assert {:error, _} = SSH.command(c.endpoint, c.request, %{files | identity_file: path})
    end

    for request <- [
          Map.put(c.request, :command, "sh"),
          Map.put(c.request, :kind, :full),
          %{c.request | relocation_id: "-oProxyCommand=sh"}
        ] do
      assert {:error, _} = SSH.command(c.endpoint, request, files)
    end
  end
end
