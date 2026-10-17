defmodule Brady.AttributionTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.EgressAttribution, as: Wire
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
    path = Path.join(System.tmp_dir!(), "brady-client-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: 2])

    {:ok, %{uid: uid}} = File.stat(path)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    %{path: path, listener: listener, uid: uid}
  end

  test "client validates host and authenticated peer before accepting identity", ctx do
    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(ctx.listener)
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
        assert Wire.decode_request(bytes) == {:ok, @flow}
        :gen_tcp.send(socket, Wire.response({:ok, @identity}))
        :gen_tcp.close(socket)
      end)

    assert Brady.Attribution.request(ctx.path, @id, @flow, ctx.uid) == @identity
    Task.await(task)
  end

  test "wrong server UID receives no flow tuple", ctx do
    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(ctx.listener)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
      end)

    assert Brady.Attribution.request(ctx.path, @id, @flow, ctx.uid + 1) ==
             %{host_id: @id, attribution: :unresolved}

    Task.await(task)
  end

  test "wrong host remains unresolved", ctx do
    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(ctx.listener)
        {:ok, _} = :gen_tcp.recv(socket, 0, 1000)
        :gen_tcp.send(socket, Wire.response({:ok, @identity}))
        :gen_tcp.close(socket)
      end)

    other = "22222222-2222-4222-8222-222222222222"

    assert Brady.Attribution.request(ctx.path, other, @flow, ctx.uid) ==
             %{host_id: other, attribution: :unresolved}

    Task.await(task)
  end
end
