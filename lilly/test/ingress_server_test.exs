defmodule Lilly.IngressServerTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.IngressConnect, as: Wire
  @id "11111111-1111-4111-8111-111111111111"

  defmodule Backend do
    def open({parent, port, guardian}, binding) do
      send(parent, {:opened, binding})

      with {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false]),
           do: {:ok, socket, guardian}
    end
  end

  defmodule HungBackend do
    def open(parent, _) do
      send(parent, :setup_started)

      receive do
        :never -> {:error, :connector_unavailable}
      end
    end
  end

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        # unique_integer restarts in every VM; a random suffix cannot collide
        # with a directory a crashed or concurrent run left behind.
        "lilly-ingress-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir!(directory)
    {:ok, %{uid: uid}} = File.stat(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    binding = %{
      vm_id: @id,
      host_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      service: :ssh,
      port: 22,
      label: OverallsProtocol.IngressName.label("vm", @id)
    }

    %{path: Path.join(directory, "connector.sock"), uid: uid, binding: binding}
  end

  defp client(path),
    do: :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: 4], 1000)

  defp echo(socket, parent) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, bytes} ->
        :gen_tcp.send(socket, bytes)
        echo(socket, parent)

      _ ->
        send(parent, :guest_closed)
        :gen_tcp.close(socket)
    end
  end

  test "local handshake relays bytes and guardian death closes both sockets", ctx do
    parent = self()

    guardian =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(guardian, :kill) end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        echo(socket, parent)
      end)

    start_supervised!(
      {Lilly.Ingress.Server,
       path: ctx.path,
       audi_uid: ctx.uid,
       host_id: @id,
       backend: {Backend, {parent, port, guardian}}}
    )

    {:ok, client} = client(ctx.path)
    {:ok, message} = Wire.encode(ctx.binding)
    :ok = :gen_tcp.send(client, message)
    assert {:ok, ready} = :gen_tcp.recv(client, 0, 1000)
    assert Wire.ready?(ready)
    assert_receive {:opened, binding}
    assert binding == ctx.binding
    :inet.setopts(client, packet: 0)
    :gen_tcp.send(client, "opaque SSH bytes")
    assert {:ok, "opaque SSH bytes"} = :gen_tcp.recv(client, 16, 1000)
    send(guardian, :stop)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1500)
    assert_receive :guest_closed, 1500
    Task.await(task)
    :gen_tcp.close(listener)
  end

  test "wrong UID never reaches the backend", ctx do
    start_supervised!(
      {Lilly.Ingress.Server,
       path: ctx.path,
       audi_uid: ctx.uid + 1,
       host_id: @id,
       backend: {Backend, {self(), 1, self()}}}
    )

    {:ok, client} = client(ctx.path)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1000)
    refute_receive {:opened, _}
  end

  test "a missing backend denies a valid request", ctx do
    start_supervised!({Lilly.Ingress.Server, path: ctx.path, audi_uid: ctx.uid, host_id: @id})
    {:ok, valid} = Wire.encode(ctx.binding)
    {:ok, client} = client(ctx.path)
    :gen_tcp.send(client, valid)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1500)
  end

  test "wrong host and malformed requests never reach an available backend", ctx do
    start_supervised!(
      {Lilly.Ingress.Server,
       path: ctx.path, audi_uid: ctx.uid, host_id: @id, backend: {Backend, {self(), 1, self()}}}
    )

    {:ok, wrong_host} =
      Wire.encode(%{ctx.binding | host_id: "22222222-2222-4222-8222-222222222222"})

    for message <- [
          wrong_host,
          ~s({"version":1,"address":"127.0.0.1"}),
          <<0::size(2049 * 8)>>
        ] do
      {:ok, client} = client(ctx.path)
      :gen_tcp.send(client, message)
      assert {:error, :closed} = :gen_tcp.recv(client, 0, 1500)
    end

    refute_receive {:opened, _}
  end

  test "an existing filesystem entry is never replaced", ctx do
    Process.flag(:trap_exit, true)
    File.write!(ctx.path, "keep")

    assert {:error, :connector_unavailable} =
             Lilly.Ingress.Server.start_link(path: ctx.path, audi_uid: ctx.uid, host_id: @id)

    assert File.read!(ctx.path) == "keep"
  end

  test "a crashed owner is recovered but a live owner cannot be replaced", ctx do
    Process.flag(:trap_exit, true)
    options = [path: ctx.path, audi_uid: ctx.uid, host_id: @id]
    {:ok, first} = Lilly.Ingress.Server.start_link(options)
    ref = Process.monitor(first)
    assert {:error, :connector_unavailable} = Lilly.Ingress.Server.start_link(options)
    assert {:ok, socket} = client(ctx.path)
    :gen_tcp.close(socket)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}
    assert {:ok, %{type: :other}} = File.lstat(ctx.path)
    second = start_supervised!({Lilly.Ingress.Server, options})
    assert Process.alive?(second)
    assert {:ok, socket} = client(ctx.path)
    :gen_tcp.close(socket)
  end

  test "a claimed path still rejects replacement files and symlinks", ctx do
    Process.flag(:trap_exit, true)
    options = [path: ctx.path, audi_uid: ctx.uid, host_id: @id]
    {:ok, first} = Lilly.Ingress.Server.start_link(options)
    GenServer.stop(first)
    File.write!(ctx.path, "keep")
    assert {:error, :connector_unavailable} = Lilly.Ingress.Server.start_link(options)
    assert File.read!(ctx.path) == "keep"
    File.rename!(ctx.path, ctx.path <> ".real")
    File.ln_s!(ctx.path <> ".real", ctx.path)
    assert {:error, :connector_unavailable} = Lilly.Ingress.Server.start_link(options)
    assert File.read_link!(ctx.path) == ctx.path <> ".real"
  end

  test "an unclaimed live socket is never adopted", ctx do
    Process.flag(:trap_exit, true)
    {:ok, listener} = :gen_tcp.listen(0, ifaddr: {:local, ctx.path}, active: false)

    assert {:error, :connector_unavailable} =
             Lilly.Ingress.Server.start_link(path: ctx.path, audi_uid: ctx.uid, host_id: @id)

    assert {:ok, socket} = client(ctx.path)
    :gen_tcp.close(socket)
    :gen_tcp.close(listener)
  end

  test "writable socket directories are rejected before creating a socket", ctx do
    Process.flag(:trap_exit, true)
    File.chmod!(Path.dirname(ctx.path), 0o777)

    assert {:error, :connector_unavailable} =
             Lilly.Ingress.Server.start_link(
               path: ctx.path,
               audi_uid: ctx.uid,
               host_id: @id
             )

    refute File.exists?(ctx.path)
  end

  test "a hung backend is killed at the setup deadline and excess clients are rejected", ctx do
    start_supervised!(
      {Lilly.Ingress.Server,
       path: ctx.path,
       audi_uid: ctx.uid,
       host_id: @id,
       max_connections: 1,
       backend: {HungBackend, self()}}
    )

    {:ok, first} = client(ctx.path)
    {:ok, message} = Wire.encode(ctx.binding)
    :gen_tcp.send(first, message)
    assert_receive :setup_started
    {:ok, excess} = client(ctx.path)
    assert {:error, :closed} = :gen_tcp.recv(excess, 0, 1000)
    assert {:error, :closed} = :gen_tcp.recv(first, 0, 2500)
  end
end
