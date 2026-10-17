defmodule Lilly.Lifecycle.PublicationDiagnosticsTest do
  use ExUnit.Case, async: false
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.{Dataset, Journal}
  @moduletag :tmp_dir

  # @cc [owner:ghuntley,label:verification;concurrency;recovery] native-writer-before-diagnostic-wait
  # Spool I/O MUST begin only after the native writer releases. A held/refused
  # spool reply MUST NOT prevent another state transition under the same lock.
  test "native writer releases before a slow independent spool accepts", %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    socket = "/tmp/lilly-diag-" <> Lilly.UUID.generate() <> ".sock"
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    previous = System.get_env("OVERALLS_TRACE_SOCKET")
    System.put_env("OVERALLS_TRACE_SOCKET", socket)

    on_exit(fn ->
      if previous,
        do: System.put_env("OVERALLS_TRACE_SOCKET", previous),
        else: System.delete_env("OVERALLS_TRACE_SOCKET")

      :gen_tcp.close(listener)
      File.rm(socket)
    end)

    owner = self()

    spool =
      Task.async(fn ->
        target =
          receive do
            {:target, id} -> id
          after
            5_000 -> flunk("fixture transition identity was not supplied")
          end

        {connection, body} = matching_request(listener, target)
        {:ok, proof} = Lock.acquire(root)
        assert :ok = Lock.release(proof)
        send(owner, :spool_waiting_after_release)

        receive do
          :finish -> :ok
        after
          5_000 -> flunk("spool fixture was not released")
        end

        _ =
          :gen_tcp.send(
            connection,
            "HTTP/1.1 204 Test\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

        :gen_tcp.close(connection)
        body
      end)

    payload = %{
      "state" => "creating",
      "binding" => %{
        "host_id" => Lilly.UUID.generate(),
        "spec" => %{"id" => Lilly.UUID.generate()}
      }
    }

    {:ok, writer} = Lock.acquire(root)
    assert :ok = Journal.write(Dataset, root, "claim.json", payload)
    assert {:ok, record} = Journal.load(Dataset, root, "claim.json")
    send(spool.pid, {:target, record.id})
    refute_receive :spool_waiting_after_release, 150
    assert :ok = Lock.release(writer)
    assert_receive :spool_waiting_after_release, 5_000
    {:ok, writer} = Lock.acquire(root)
    assert :ok = Journal.write(Dataset, root, "claim.json", %{payload | "state" => "bound"})
    assert :ok = Lock.release(writer)
    assert {:ok, %{state: :bound, revision: 2}} = Journal.load(Dataset, root, "claim.json")
    send(spool.pid, :finish)
    assert Task.await(spool, 5_000) != ""
  end

  @spec matching_request(port(), String.t()) :: {port(), binary()}
  defp matching_request(listener, target) do
    {:ok, connection} = :gen_tcp.accept(listener, 5_000)
    body = request(connection, "")

    %{resource_spans: resources} =
      :opentelemetry_exporter_trace_service_pb.decode_msg(body, :export_trace_service_request)

    matching =
      Enum.any?(resources, fn %{scope_spans: scopes} ->
        Enum.any?(scopes, fn %{spans: spans} ->
          Enum.any?(spans, fn %{attributes: attributes} ->
            Enum.any?(
              attributes,
              fn
                %{key: "resource_id", value: %{value: {:string_value, ^target}}} -> true
                _ -> false
              end
            )
          end)
        end)
      end)

    if matching do
      {connection, body}
    else
      :ok =
        :gen_tcp.send(
          connection,
          "HTTP/1.1 204 Test\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        )

      :gen_tcp.close(connection)
      matching_request(listener, target)
    end
  end

  @spec request(port(), binary()) :: binary()
  defp request(socket, bytes) when byte_size(bytes) <= 262_144 + 8192 do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, count] = Regex.run(~r/content-length: ([0-9]+)/i, headers)
        length = String.to_integer(count)
        assert length <= 262_144
        if byte_size(body) == length, do: body, else: receive_more(socket, bytes)

      [_] ->
        receive_more(socket, bytes)
    end
  end

  @spec receive_more(port(), binary()) :: binary()
  defp receive_more(socket, bytes) do
    {:ok, next} = :gen_tcp.recv(socket, 0, 5_000)
    request(socket, bytes <> next)
  end
end
