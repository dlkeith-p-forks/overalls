defmodule Lilly.Terminal.VsockTest do
  use ExUnit.Case, async: true

  alias Lilly.Terminal.Vsock

  @identity %{
    uds_path: "/tmp/lilly-terminal-test.sock",
    placement_id: "11111111-1111-4111-8111-111111111111",
    execution_epoch: 4,
    boot_challenge: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  }

  test "invalid Firecracker handshake closes before sending terminal authority" do
    path =
      Path.join(System.tmp_dir!(), "terminal-rejected-#{System.unique_integer([:positive])}.sock")

    identity = %{@identity | uds_path: path}
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1000)
        assert {:ok, "CONNECT 1075\n"} = :gen_tcp.recv(socket, 13, 1000)
        :ok = :gen_tcp.send(socket, "NO\n")
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
      end)

    assert {:error, :handshake_failed} = Vsock.connect(identity)
    Task.await(server)
  end

  test "a fresh guest manager recovers a live session token before attaching" do
    path =
      Path.join(System.tmp_dir!(), "terminal-recovery-#{System.unique_integer([:positive])}.sock")

    identity = %{@identity | uds_path: path}
    token = :crypto.strong_rand_bytes(16)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    server =
      Task.async(fn ->
        {:ok, control} = :gen_tcp.accept(listener, 1000)
        authenticate(control, identity)
        assert {:ok, <<0x4C, 11, 8::16, 9::64>>} = :gen_tcp.recv(control, 12, 1000)
        :ok = :gen_tcp.send(control, <<0x4C, 0x80, 16::16, token::binary>>)
        {:ok, attachment} = :gen_tcp.accept(listener, 1000)
        authenticate(attachment, identity)

        assert {:ok, <<0x4C, 10, 37::16, 9::64, ^token::binary-size(16), 0, 0::64, 0::16, 0::16>>} =
                 :gen_tcp.recv(attachment, 41, 1000)

        :ok = :gen_tcp.send(attachment, <<0x4C, 0x80, 12::16, 0::64, 3::32, "old">>)
        assert {:error, :closed} = :gen_tcp.recv(attachment, 0, 1000)
        :gen_tcp.close(control)
      end)

    manager =
      start_supervised!(%{
        id: Lilly.Terminal.Guest,
        start: {Lilly.Terminal.Guest, :start_link, [self(), identity]}
      })

    assert {:ok, %{socket: socket, replay: "", replay_bytes: 3}} =
             Lilly.Terminal.Guest.attach(manager, 9, :ro, 0)

    assert {:ok, "old"} = :gen_tcp.recv(socket, 3, 1000)

    :ok = Vsock.close(socket)
    Task.await(server)
  end

  @spec authenticate(:gen_tcp.socket(), Vsock.identity()) :: :ok
  defp authenticate(socket, identity) do
    firecracker_connect(socket)

    assert {:ok, <<0x4C, 1, 48::16, nonce::binary-size(16), tag::binary-size(32)>>} =
             :gen_tcp.recv(socket, 52, 1000)

    assert tag == Vsock.hello_tag(identity, nonce)
    :gen_tcp.send(socket, <<0x4C, 0x80, 0::16>>)
  end

  @spec firecracker_connect(:gen_tcp.socket()) :: :ok
  defp firecracker_connect(socket) do
    assert {:ok, "CONNECT 1075\n"} = :gen_tcp.recv(socket, 13, 1000)
    :gen_tcp.send(socket, "OK 12345\n")
  end

  test "attach authenticates its connection before presenting the session token" do
    path =
      Path.join(System.tmp_dir!(), "terminal-vsock-#{System.unique_integer([:positive])}.sock")

    identity = %{@identity | uds_path: path}
    token = :binary.copy(<<0x5A>>, 16)
    parent = self()

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}])

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1000)

        firecracker_connect(socket)

        assert {:ok, <<0x4C, 1, 48::16, nonce::binary-size(16), tag::binary-size(32)>>} =
                 :gen_tcp.recv(socket, 52, 1000)

        assert tag == Vsock.hello_tag(identity, nonce)
        :ok = :gen_tcp.send(socket, <<0x4C, 0x80, 0::16>>)

        assert {:ok,
                <<0x4C, 10, 37::16, 9::64, ^token::binary-size(16), 1, 17::64, 0::16, 0::16>>} =
                 :gen_tcp.recv(socket, 41, 1000)

        :ok = :gen_tcp.send(socket, <<0x4C, 0x80, 12::16, 17::64, 3::32, "old">>)
        send(parent, :attach_protocol_observed)
        Process.sleep(100)
        :gen_tcp.close(socket)
      end)

    assert {:ok, %{socket: socket, from: 17, replay: "old"}} =
             Vsock.attach(identity, 9, token, :rw, 17)

    assert_receive :attach_protocol_observed
    Vsock.close(socket)
    Task.await(server)
    :gen_tcp.close(listener)
    File.rm(path)
  end
end
