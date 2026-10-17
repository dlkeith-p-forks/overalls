defmodule Lilly.VM.CredentialsTest do
  use ExUnit.Case, async: true
  alias Lilly.VM.Credentials

  @expected %{
    placement_id: "11111111-1111-4111-8111-111111111111",
    execution_epoch: 7,
    boot_challenge: String.duplicate("a", 64)
  }
  @smtp %{
    "version" => 1,
    "host" => "smtp.example.test",
    "port" => 587,
    "username" => "fixture",
    "password" => "synthetic-test-password",
    "from" => "dev@example.test",
    "tls" => "starttls"
  }

  setup do
    root =
      Path.join(System.tmp_dir!(), "inception-credentials-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "smtp.json")
    File.write!(path, JSON.encode!(@smtp))
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: path}
  end

  test "only a private SMTP file can be loaded", %{path: path} do
    assert {:ok, @smtp} = Credentials.load(path)
    File.chmod!(path, 0o644)
    assert {:error, :inception_credentials_unavailable} = Credentials.load(path)
    File.chmod!(path, 0o600)
    File.ln_s!(path, path <> ".link")
    assert {:error, :inception_credentials_unavailable} = Credentials.load(path <> ".link")
    File.ln!(path, path <> ".hard")
    assert {:error, :inception_credentials_unavailable} = Credentials.load(path)
    assert {:error, :inception_credentials_unavailable} = Credentials.load(nil)
    assert {:error, :inception_credentials_unavailable} = Credentials.load("/nix/store/smtp.json")
  end

  test "extra secrets, malformed SMTP and invalid CA fail without source details", %{path: path} do
    for bundle <- [
          Map.put(@smtp, "database_password", "forbidden"),
          Map.put(@smtp, "tls", "none"),
          Map.put(@smtp, "password", "line\nbreak"),
          Map.put(@smtp, "ca_pem", "not a certificate"),
          Map.put(@smtp, "port", true),
          Map.put(@smtp, "version", 1.0),
          Map.delete(@smtp, "username")
        ] do
      File.write!(path, JSON.encode!(bundle))
      assert {:error, :inception_credentials_unavailable} = Credentials.load(path)
    end
  end

  defp ack do
    @expected
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"version" => 1, "state" => "configured"})
  end

  defp server(root, callback) do
    path = Path.join(root, "v.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}, packet: :line])

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          assert {:ok, "CONNECT 1025\n"} = :gen_tcp.recv(socket, 0, 1000)
          callback.(socket)
        after
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn -> :gen_tcp.close(listener) end)
    {path, task}
  end

  test "fragmented handshake delivers only SMTP and verifies boot-bound acknowledgment", %{
    root: root
  } do
    {path, task} =
      server(root, fn socket ->
        :ok = :gen_tcp.send(socket, "O")
        :ok = :gen_tcp.send(socket, "K 1234\n")
        assert {:ok, body} = :gen_tcp.recv(socket, 0, 1000)
        assert JSON.decode!(body) == Map.merge(Map.delete(ack(), "state"), %{"smtp" => @smtp})
        :ok = :gen_tcp.send(socket, JSON.encode!(ack()) <> "\n")
      end)

    assert :ok = Credentials.deliver(path, @expected, @smtp, 1000)
    Task.await(task)
  end

  # inception-host-delivery-bound: one caller deadline bounds every step. The
  # caller timeout leaves the fixture's handshake room on a loaded host, and the
  # silent guest stalls far beyond timeout plus an explicit scheduler tolerance,
  # so the bound separates "cut short by the deadline" from "extended by the
  # guest" without depending on sub-second scheduling.
  @delivery_timeout_ms 1000
  @scheduler_tolerance_ms 2000
  @silent_stall_ms 30_000

  test "stale acknowledgment and unresponsive guest cannot extend the deadline", %{root: root} do
    for response <- [:stale, :silent] do
      directory = Path.join(root, Atom.to_string(response))
      File.mkdir_p!(directory)

      {path, task} =
        server(directory, fn socket ->
          :ok = :gen_tcp.send(socket, "OK 1234\n")
          assert {:ok, _} = :gen_tcp.recv(socket, 0, @delivery_timeout_ms)

          if response == :stale do
            :gen_tcp.send(socket, JSON.encode!(Map.put(ack(), "execution_epoch", 8)) <> "\n")
          else
            Process.sleep(@silent_stall_ms)
          end
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, :inception_credentials_unavailable} =
               Credentials.deliver(path, @expected, @smtp, @delivery_timeout_ms)

      assert System.monotonic_time(:millisecond) - started <
               @delivery_timeout_ms + @scheduler_tolerance_ms

      if response == :stale, do: Task.await(task), else: Task.shutdown(task, :brutal_kill)
    end
  end

  test "failed Firecracker handshake never receives credentials", %{root: root} do
    {path, task} =
      server(root, fn socket ->
        :ok = :gen_tcp.send(socket, "OK 0\n")
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
      end)

    assert {:error, :inception_credentials_unavailable} =
             Credentials.deliver(path, @expected, @smtp, 100)

    Task.await(task)
  end

  test "invalid requests are rejected before connection" do
    for {path, expected, smtp, timeout} <- [
          {"relative", @expected, @smtp, 100},
          {"/socket", Map.put(@expected, :execution_epoch, 0), @smtp, 100},
          {"/socket", @expected, Map.put(@smtp, "extra", "forbidden"), 100},
          {"/socket", @expected, @smtp, 0}
        ] do
      assert {:error, :inception_credentials_unavailable} =
               Credentials.deliver(path, expected, smtp, timeout)
    end
  end
end
