defmodule Peach.HTTPTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias Peach.Fixtures

  test "serves the validated projection on each public path" do
    parent = self()

    control =
      Peach.ControlStub.start(fn "peach.snapshot", body ->
        send(parent, {:body, body})
        {:ok, Fixtures.snapshot()}
      end)

    config = Fixtures.config(control)

    root = call(config, "/")
    assert root.status == 200
    assert ["no-store"] = Plug.Conn.get_resp_header(root, "cache-control")
    decoded = Jason.decode!(root.resp_body)
    assert decoded["guest"]["id"] == Fixtures.binding()["vm_id"]
    assert Enum.map(decoded["paths"], & &1["path"]) == ["/guest", "/integrations"]
    assert_received {:body, %{"version" => 1, "binding" => binding}}
    assert binding == Fixtures.binding()

    assert Jason.decode!(call(config, "/guest").resp_body)["name"] == "guest"
    assert [%{"name" => "llm"}] = Jason.decode!(call(config, "/integrations").resp_body)
  end

  test "refuses a snapshot for a different guest than the binding" do
    other = "66666666-6666-4666-8666-666666666666"
    control = Peach.ControlStub.start(fn _, _ -> {:ok, Fixtures.snapshot(%{"id" => other})} end)
    conn = call(Fixtures.config(control), "/")
    assert conn.status == 503
    refute conn.resp_body =~ other
  end

  test "a disconnected control link is an outage, not a projection" do
    control = %{client: :peach_missing_client}
    assert call(Fixtures.config(control), "/").status == 503
  end

  test "duplicated binding headers are refused" do
    control = Peach.ControlStub.start(fn _, _ -> {:ok, Fixtures.snapshot()} end)
    encoded = Fixtures.encode(Fixtures.binding())

    conn =
      conn(:get, "/")
      |> Map.update!(
        :req_headers,
        &[{"x-overalls-binding", encoded}, {"x-overalls-binding", encoded} | &1]
      )

    assert Peach.HTTP.call(conn, Fixtures.config(control)).status == 403
    refute_received {:control_request, _}
  end

  test "serves over the configured Unix socket" do
    control = Peach.ControlStub.start(fn _, _ -> {:ok, Fixtures.snapshot()} end)
    dir = Path.join(System.tmp_dir!(), "peach-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    socket = Path.join(dir, "reflection.sock")
    config = %{Fixtures.config(control) | socket: socket}

    start_supervised!(
      {Bandit, plug: {Peach.HTTP, config}, ip: {:local, socket}, port: 0, startup_log: false}
    )

    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(socket)}, 0, [:binary, active: false])

    request =
      "GET /guest HTTP/1.1\r\nhost: reflection.internal\r\nx-overalls-binding: " <>
        Fixtures.encode(Fixtures.binding()) <> "\r\nconnection: close\r\n\r\n"

    :ok = :gen_tcp.send(sock, request)
    response = read_all(sock, "")
    assert response =~ "HTTP/1.1 200"
    assert response =~ ~s("name":"guest")
  end

  defp read_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} -> read_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp call(config, path) do
    conn(:get, path)
    |> Plug.Conn.put_req_header("x-overalls-binding", Fixtures.encode(Fixtures.binding()))
    |> Peach.HTTP.call(config)
  end
end
