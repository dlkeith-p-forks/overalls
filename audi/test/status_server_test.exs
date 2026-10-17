defmodule Audi.StatusServerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "audi-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.chmod!(dir, 0o700)
    %{path: Path.join(dir, "status.sock")}
  end

  test "fresh bounded readiness responses survive restart without exposing details", c do
    state = start_supervised!({Agent, fn -> true end})

    options = [
      path: c.path,
      client: nil,
      role: :gateway,
      health: fn -> Agent.get(state, & &1) end
    ]

    start_supervised!({Audi.StatusServer, options})
    assert snapshot(c.path) == %{"version" => 1, "role" => "gateway", "ready" => true}
    Agent.update(state, fn _ -> false end)
    assert snapshot(c.path) == %{"version" => 1, "role" => "gateway", "ready" => false}
    assert Bitwise.band(File.stat!(c.path).mode, 0o777) == 0o600

    assert {:error, _} =
             start_supervised(Supervisor.child_spec({Audi.StatusServer, options}, id: :duplicate))

    :ok = stop_supervised(Audi.StatusServer)
    start_supervised!({Audi.StatusServer, options})
    assert snapshot(c.path) == %{"version" => 1, "role" => "gateway", "ready" => false}
  end

  test "existing files and unsafe directories fail closed", c do
    File.write!(c.path, "retain")

    assert {:error, _} =
             start_supervised({Audi.StatusServer, [path: c.path, client: nil, role: :gateway]})

    assert File.read!(c.path) == "retain"
    File.rm!(c.path)
    File.chmod!(Path.dirname(c.path), 0o755)

    assert {:error, _} =
             start_supervised({Audi.StatusServer, [path: c.path, client: nil, role: :gateway]})
  end

  test "a shared 0750 directory makes the socket group-connectable only", c do
    File.chmod!(Path.dirname(c.path), 0o750)
    start_supervised!({Audi.StatusServer, [path: c.path, client: nil, role: :private]})
    assert Bitwise.band(File.stat!(c.path).mode, 0o777) == 0o660
    assert %{"version" => 1, "role" => "private"} = snapshot(c.path)
    :ok = stop_supervised(Audi.StatusServer)

    # Group write or any other-user permission is still refused.
    for mode <- [0o770, 0o751] do
      File.rm(c.path)
      File.chmod!(Path.dirname(c.path), mode)

      assert {:error, _} =
               start_supervised({Audi.StatusServer, [path: c.path, client: nil, role: :private]})
    end
  end

  test "health exceptions return only fixed unavailability", c do
    start_supervised!(
      {Audi.StatusServer,
       [path: c.path, client: nil, role: :gateway, health: fn -> raise "private diagnostic" end]}
    )

    assert snapshot(c.path) == %{"version" => 1, "role" => "gateway", "ready" => false}
  end

  test "a stalled check is killed at the deadline and does not prevent the next check", c do
    parent = self()
    state = start_supervised!({Agent, fn -> :stall end})

    health = fn ->
      case Agent.get(state, & &1) do
        :stall ->
          send(parent, {:checking, self()})

          receive do
            :never_sent -> true
          end

        :ready ->
          true
      end
    end

    start_supervised!({Audi.StatusServer, path: c.path, client: nil, role: :dns, health: health})

    {:ok, socket} =
      :gen_tcp.connect({:local, c.path}, 0, [:binary, active: false, packet: :line], 1000)

    assert_receive {:checking, worker}, 1000
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 6000
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
    :gen_tcp.close(socket)
    assert JSON.decode!(bytes) == %{"version" => 1, "role" => "dns", "ready" => false}
    Agent.update(state, fn _ -> :ready end)
    assert snapshot(c.path) == %{"version" => 1, "role" => "dns", "ready" => true}
  end

  defp snapshot(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line], 1000)

    {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
    :gen_tcp.close(socket)
    JSON.decode!(bytes)
  end
end
