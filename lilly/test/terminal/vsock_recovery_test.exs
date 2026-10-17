defmodule Lilly.Terminal.VsockRecoveryTest do
  use ExUnit.Case, async: true
  alias Lilly.Terminal.Vsock

  @identity %{
    uds_path: "",
    placement_id: "11111111-1111-4111-8111-111111111111",
    execution_epoch: 1,
    boot_challenge: String.duplicate("ab", 32)
  }

  test "only not-found is an unknown request; any other guest error fails the probe" do
    {identity, listener} = listener()
    supervisor = start_supervised!(Task.Supervisor)

    server =
      Task.Supervisor.async(supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1000)
        authenticate(socket)

        for code <- [5, 2] do
          assert {:ok, <<0x4C, 13, 16::16, _request::binary-size(16)>>} =
                   :gen_tcp.recv(socket, 20, 1000)

          :ok = :gen_tcp.send(socket, <<0x4C, 0x81, 1::16, code>>)
        end

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
      end)

    assert {:ok, socket} = Vsock.connect(identity)
    request_id = "22222222-2222-4222-8222-222222222222"

    assert {:error, :handshake_failed} = Vsock.creation_status(socket, request_id)

    assert {:ok, %{state: :unknown, guest_session_id: nil}} =
             Vsock.creation_status(socket, request_id)

    :ok = Vsock.close(socket)
    Task.await(server)
  end

  test "rejected authentication closes the dialed connection" do
    {identity, listener} = listener()
    supervisor = start_supervised!(Task.Supervisor)

    server =
      Task.Supervisor.async(supervisor, fn ->
        # Fake-peer waits are event bounds, generous for a loaded host.
        {:ok, socket} = :gen_tcp.accept(listener, 5000)
        firecracker(socket)

        assert {:ok, <<0x4C, 1, 48::16, _proof::binary-size(48)>>} =
                 :gen_tcp.recv(socket, 52, 5000)

        :ok = :gen_tcp.send(socket, <<0x4C, 0x81, 1::16, 1>>)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5000)
      end)

    assert {:error, :rejected} = Vsock.connect(identity)
    Task.await(server)
  end

  test "maximum-size usernames in a full guest listing fit the bounded control frame" do
    {identity, listener} = listener()
    supervisor = start_supervised!(Task.Supervisor)

    server =
      Task.Supervisor.async(supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1000)
        authenticate(socket)
        assert {:ok, <<0x4C, 3, 0::16>>} = :gen_tcp.recv(socket, 4, 1000)

        entries =
          for id <- 1..64, into: <<>> do
            <<id::64, 64, String.duplicate("u", 64)::binary, 80::16, 24::16, 0::16, 1, 1::64,
              1::64>>
          end

        payload = <<64::16, entries::binary>>
        assert byte_size(payload) > 4096
        :ok = :gen_tcp.send(socket, <<0x4C, 0x80, byte_size(payload)::16, payload::binary>>)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
      end)

    assert {:ok, socket} = Vsock.connect(identity)
    assert {:ok, sessions} = Vsock.list(socket)
    assert length(sessions) == 64
    assert Enum.all?(sessions, &(byte_size(&1.user) == 64))
    :ok = Vsock.close(socket)
    Task.await(server)
  end

  @spec listener() :: {Vsock.identity(), :gen_tcp.socket()}
  defp listener do
    path =
      Path.join(
        System.tmp_dir!(),
        "terminal-recovery-bounds-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    {%{@identity | uds_path: path}, listener}
  end

  @spec firecracker(:gen_tcp.socket()) :: :ok
  defp firecracker(socket) do
    assert {:ok, "CONNECT 1075\n"} = :gen_tcp.recv(socket, 13, 1000)
    :gen_tcp.send(socket, "OK 12345\n")
  end

  @spec authenticate(:gen_tcp.socket()) :: :ok
  defp authenticate(socket) do
    :ok = firecracker(socket)
    assert {:ok, <<0x4C, 1, 48::16, _proof::binary-size(48)>>} = :gen_tcp.recv(socket, 52, 1000)
    :gen_tcp.send(socket, <<0x4C, 0x80, 0::16>>)
  end
end
