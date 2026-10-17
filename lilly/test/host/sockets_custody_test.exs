defmodule Lilly.Host.SocketsCustodyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Lilly.Host.Sockets

  # The BEAM connects the owned socket itself here, in place of lilly-hostd,
  # so the custody of a socket Lilly created is exercised without root.

  setup do
    # sun_path holds 108 bytes, so the listener gets a short directory.
    dir = Path.join(System.tmp_dir!(), "custody-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "s.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, String.to_charlist(path)}}, active: false])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(dir)
    end)

    %{path: path, listener: listener}
  end

  # @cc [owner:ghuntley,label:verification] owned-socket-custody-property
  # Over random mixes of explicit close, owner death and controlling_process
  # transfer (closed or abandoned by the new owner), every adopted socket MUST
  # carry bytes, its peer MUST see end of stream, and the test process's
  # descriptor count MUST return to its baseline.
  property "adopted sockets are released exactly when their port goes down", context do
    check all(
            endings <-
              list_of(member_of([:close, :owner_dies, :transfer_close, :transfer_dies]),
                max_length: 8
              )
          ) do
      baseline = descriptors()
      peers = Enum.map(endings, &exercise(context, &1))

      for peer <- peers do
        assert {:error, :closed} = :gen_tcp.recv(peer, 0, 2000)
        :gen_tcp.close(peer)
      end

      assert settles(baseline)
    end
  end

  test "a refused port closes the owned socket at once", context do
    baseline = descriptors()
    {owned, peer} = owned(context)
    assert {:error, _} = Sockets.adopt(owned, [{:packet, :nonsense}])
    assert {:error, :closed} = :gen_tcp.recv(peer, 0, 2000)
    :gen_tcp.close(peer)
    assert settles(baseline)
  end

  defp owned(%{path: path, listener: listener}) do
    {:ok, owned} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(owned, %{family: :local, path: path})
    {:ok, peer} = :gen_tcp.accept(listener, 2000)
    {owned, peer}
  end

  defp exercise(context, ending) do
    parent = self()

    owner =
      spawn(fn ->
        {owned, peer} = owned(context)
        {:ok, socket} = Sockets.adopt(owned, [:binary, active: false])
        :ok = :gen_tcp.controlling_process(peer, parent)
        send(parent, {:adopted, self(), socket, peer})

        receive do
          :finish -> finish(socket, ending, parent)
        end
      end)

    assert_receive {:adopted, ^owner, socket, peer}, 2000
    :ok = :gen_tcp.send(peer, "down")
    reference = Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^reference, :process, ^owner, _}, 2000
    _ = socket
    peer
  end

  defp finish(socket, ending, parent) do
    {:ok, "down"} = :gen_tcp.recv(socket, 4, 2000)

    case ending do
      :close ->
        :gen_tcp.close(socket)

      :owner_dies ->
        :ok

      transfer ->
        heir =
          spawn(fn ->
            receive do
              :go -> if transfer == :transfer_close, do: :gen_tcp.close(socket)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, heir)
        reference = Process.monitor(heir)
        send(heir, :go)

        receive do
          {:DOWN, ^reference, :process, ^heir, _} -> :ok
        end
    end

    _ = parent
  end

  defp descriptors, do: "/proc/self/fd" |> File.ls!() |> length()

  defp settles(baseline, attempts \\ 200) do
    cond do
      descriptors() <= baseline ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        settles(baseline, attempts - 1)
    end
  end
end
