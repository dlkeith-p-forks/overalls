defmodule Porsche.StatusServerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "porsche-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.chmod!(dir, 0o700)
    %{path: Path.join(dir, "status.sock")}
  end

  test "fresh bounded readiness responses survive restart without exposing details", c do
    state = start_supervised!({Agent, fn -> true end})
    options = [path: c.path, client: nil, health: fn -> Agent.get(state, & &1) end]
    start_supervised!({Porsche.StatusServer, options})
    assert snapshot(c.path) == %{"version" => 1, "ready" => true}
    Agent.update(state, fn _ -> false end)
    assert snapshot(c.path) == %{"version" => 1, "ready" => false}
    assert Bitwise.band(File.stat!(c.path).mode, 0o777) == 0o600

    assert {:error, _} =
             start_supervised(
               Supervisor.child_spec({Porsche.StatusServer, options}, id: :duplicate)
             )

    :ok = stop_supervised(Porsche.StatusServer)
    start_supervised!({Porsche.StatusServer, options})
    assert snapshot(c.path) == %{"version" => 1, "ready" => false}
  end

  test "existing files and unsafe directories fail closed", c do
    File.write!(c.path, "retain")
    assert {:error, _} = start_supervised({Porsche.StatusServer, [path: c.path, client: nil]})
    assert File.read!(c.path) == "retain"
    File.rm!(c.path)
    File.chmod!(Path.dirname(c.path), 0o755)
    assert {:error, _} = start_supervised({Porsche.StatusServer, [path: c.path, client: nil]})
  end

  test "health exceptions return only fixed unavailability", c do
    start_supervised!(
      {Porsche.StatusServer,
       [path: c.path, client: nil, health: fn -> raise "private diagnostic" end]}
    )

    assert snapshot(c.path) == %{"version" => 1, "ready" => false}
  end

  defp snapshot(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line], 1000)

    {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
    :gen_tcp.close(socket)
    JSON.decode!(bytes)
  end
end
