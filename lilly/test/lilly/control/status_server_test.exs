defmodule Lilly.Control.StatusServerTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Lilly.Control.StatusServer
  @moduletag :tmp_dir

  test "socket is private, emits only public fields and fails closed without runtime" do
    dir = Path.join("/tmp", "lilly-status-" <> Lilly.UUID.generate())
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "status.sock")
    owner = self()

    runtime =
      start_supervised!(%{
        id: :runtime,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 {:"$gen_call", from, :status} ->
                   GenServer.reply(from, %{ready: true, phase: :connected, credential: "excluded"})

                   send(owner, :answered)
               end
             end
           ]}
      })

    start_supervised!({StatusServer, path: path, runtime: runtime})
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert read(path) == %{"version" => 1, "ready" => true, "phase" => "connected"}
    assert_receive :answered
    assert read(path) == %{"version" => 1, "ready" => false, "phase" => "unavailable"}
  end

  test "refuses to replace a regular file", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "status.sock")
    File.write!(path, "retained")
    assert {:error, _} = start_supervised({StatusServer, path: path})
    assert File.read!(path) == "retained"
  end

  defp read(path) do
    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 1000)
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2000)
    :gen_tcp.close(socket)
    JSON.decode!(bytes)
  end
end
