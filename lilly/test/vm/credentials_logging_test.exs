defmodule Lilly.VM.CredentialsLoggingTest do
  use ExUnit.Case, async: false
  alias Lilly.VM.Credentials
  @metadata [:event, :vm_id, :placement_id, :execution_epoch, :reason]
  @vm "11111111-1111-4111-8111-111111111111"
  @placement "22222222-2222-4222-8222-222222222222"

  @expected %{
    placement_id: @placement,
    execution_epoch: 7,
    boot_challenge: String.duplicate("a", 64)
  }

  @smtp %{
    "version" => 1,
    "host" => "smtp.example.test",
    "port" => 587,
    "username" => "fixture-username",
    "password" => "synthetic-test-password",
    "from" => "dev@example.test",
    "tls" => "starttls"
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "inception-credentials-log-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "delivery events correlate the boot and never carry the bundle", %{root: root} do
    {path, task} =
      server(root, fn socket ->
        :ok = :gen_tcp.send(socket, "OK 1234\n")
        assert {:ok, _} = :gen_tcp.recv(socket, 0, 1000)
        :ok = :gen_tcp.send(socket, JSON.encode!(ack()) <> "\n")
      end)

    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert :ok = Credentials.deliver(path, @expected, @smtp, 1000, @vm)
        Task.await(task)
      end)

    assert log =~ "lilly.vm_credentials_delivered"
    assert log =~ "vm_id=#{@vm}"
    assert log =~ "placement_id=#{@placement}"
    assert log =~ "execution_epoch=7"
    refute_bundle(log)
  end

  test "failed delivery reports a closed reason and never the bundle", %{root: root} do
    {path, task} =
      server(root, fn socket ->
        :ok = :gen_tcp.send(socket, "OK 1234\n")
        assert {:ok, _} = :gen_tcp.recv(socket, 0, 1000)
        Process.sleep(200)
      end)

    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:error, :inception_credentials_unavailable} =
                 Credentials.deliver(path, @expected, @smtp, 100, @vm)

        Task.await(task)
      end)

    assert log =~ "lilly.vm_credentials_delivery_failed"
    assert log =~ "reason=inception_credentials_unavailable"
    assert log =~ "placement_id=#{@placement}"
    refute_bundle(log)
  end

  test "an uncorrelated caller stays silent", %{root: root} do
    {path, task} =
      server(root, fn socket ->
        :ok = :gen_tcp.send(socket, "OK 1234\n")
        assert {:ok, _} = :gen_tcp.recv(socket, 0, 1000)
        :ok = :gen_tcp.send(socket, JSON.encode!(ack()) <> "\n")
      end)

    assert :ok = Credentials.deliver(path, @expected, @smtp, 1000)
    Task.await(task)
  end

  defp refute_bundle(log) do
    refute log =~ "synthetic-test-password"
    refute log =~ "fixture-username"
    refute log =~ "smtp.example.test"
    refute log =~ "dev@example.test"
    refute log =~ "starttls"
    refute log =~ String.duplicate("a", 64)
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
end
