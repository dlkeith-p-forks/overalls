defmodule Lilly.AttributionServerTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.EgressAttribution, as: Wire
  alias Lilly.Network.AttributionServer
  @id "11111111-1111-4111-8111-111111111111"
  @flow %{source: {{10, 10, 0, 2}, 12345}, destination: {{8, 8, 8, 8}, 443}}
  @identity %{
    host_id: @id,
    vm_id: @id,
    placement_id: @id,
    owner_id: @id,
    execution_epoch: 1,
    generation: 2,
    attribution: :resolved
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "brady-attribution-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, %{uid: uid}} = File.stat(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{path: Path.join(directory, "lookup.sock"), uid: uid}
  end

  defp client(path),
    do: :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: 2], 500)

  test "authenticated bounded tuple reaches resolver and only one closed response returns", ctx do
    parent = self()

    start_supervised!(
      {AttributionServer,
       path: ctx.path,
       brady_uid: ctx.uid,
       host_id: @id,
       lookup: fn flow ->
         send(parent, {:lookup, flow})
         {:ok, @identity}
       end}
    )

    {:ok, socket} = client(ctx.path)
    :ok = :gen_tcp.send(socket, Wire.request(@flow))
    assert_receive {:lookup, @flow}
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
    assert Wire.decode_response(bytes) == {:ok, @identity}
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
  end

  test "wrong UID is rejected before reading or invoking resolver", ctx do
    parent = self()

    start_supervised!(
      {AttributionServer,
       path: ctx.path,
       brady_uid: ctx.uid + 1,
       host_id: @id,
       lookup: fn _ ->
         send(parent, :unauthorized_lookup)
         {:ok, @identity}
       end}
    )

    {:ok, socket} = client(ctx.path)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    refute_receive :unauthorized_lookup
  end

  test "extra fields cannot escape the closed response", ctx do
    start_supervised!(
      {AttributionServer,
       path: ctx.path,
       brady_uid: ctx.uid,
       host_id: @id,
       lookup: fn _ -> {:ok, Map.put(@identity, :secret, "must-not-escape")} end}
    )

    {:ok, socket} = client(ctx.path)
    :ok = :gen_tcp.send(socket, Wire.request(@flow))
    assert {:ok, <<1, 0>>} = :gen_tcp.recv(socket, 0, 1000)
  end

  test "independent deadline kills a blocked resolver and bounds worker capacity", ctx do
    parent = self()

    start_supervised!(
      {AttributionServer,
       path: ctx.path,
       brady_uid: ctx.uid,
       host_id: @id,
       max_connections: 1,
       lookup: fn _ ->
         send(parent, {:blocked, self()})

         receive do
           :never -> {:error, :unresolved}
         end
       end}
    )

    {:ok, first} = client(ctx.path)
    :ok = :gen_tcp.send(first, Wire.request(@flow))
    assert_receive {:blocked, worker}
    monitor = Process.monitor(worker)
    {:ok, second} = client(ctx.path)
    assert {:error, :closed} = :gen_tcp.recv(second, 0, 500)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 3000
    assert {:error, :closed} = :gen_tcp.recv(first, 0, 500)
  end
end
