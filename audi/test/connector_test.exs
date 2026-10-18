defmodule Audi.ConnectorTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.IngressConnect, as: Wire
  @id "11111111-1111-4111-8111-111111111111"

  # @cc [owner:ghuntley,label:verification] connector-fixture-process-custody
  # Socket names MUST include the OS process ID and a VM-local unique suffix
  # so concurrent BEAM test runs cannot unlink each other's listener. Stale
  # endpoint removal MUST succeed or report absence before binding.
  defp fixture(context, response) do
    path =
      Path.join(
        System.tmp_dir!(),
        "audi-connector-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

    # A killed prior fixture can leave the filesystem socket behind; remove
    # that stale endpoint before binding the fresh test listener.
    assert File.rm(path) in [:ok, {:error, :enoent}]

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: 4])

    {:ok, %{uid: uid}} = File.stat(path)
    parent = self()

    worker =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        case :gen_tcp.recv(socket, 0, 2000) do
          {:ok, request} ->
            send(parent, {:request, Wire.decode(request)})
            :gen_tcp.send(socket, response)
            :inet.setopts(socket, packet: 0)

            case :gen_tcp.recv(socket, 0, 2000) do
              {:ok, bytes} -> :gen_tcp.send(socket, bytes)
              _ -> :ok
            end

          _ ->
            send(parent, :closed_before_request)
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      Process.unlink(worker)
      Process.exit(worker, :kill)
      :gen_tcp.close(listener)
      File.rm(path)
    end)

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

    Map.merge(context, %{options: %{path: path, uid: uid}, binding: binding})
  end

  test "verified Unix peer hands back a caller-owned raw byte stream" do
    %{options: options, binding: binding} = fixture(%{}, Wire.ready())
    assert {:ok, socket} = Audi.Connector.open(options, binding)
    assert_receive {:request, {:ok, ^binding}}
    bytes = <<0, 255, 1, 0, 3, 4>>
    assert :ok = :gen_tcp.send(socket, bytes)
    assert {:ok, ^bytes} = :gen_tcp.recv(socket, byte_size(bytes), 1000)
    :gen_tcp.close(socket)
  end

  test "wrong peer UID is rejected before disclosing any binding" do
    %{options: options, binding: binding} = fixture(%{}, Wire.ready())

    assert {:error, :connector_unavailable} =
             Audi.Connector.open(%{options | uid: options.uid + 1}, binding)

    assert_receive :closed_before_request
    refute_receive {:request, _}
  end

  test "malformed or oversized readiness cannot enable forwarding" do
    for reply <- [~s({"ready":true}), <<0::size(2049 * 8)>>] do
      %{options: options, binding: binding} = fixture(%{}, reply)
      assert {:error, :connector_unavailable} = Audi.Connector.open(options, binding)
    end
  end
end
