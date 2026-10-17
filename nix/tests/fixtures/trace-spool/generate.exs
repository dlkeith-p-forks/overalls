defmodule Overalls.TraceSpoolFixture do
  @moduledoc "Generate native fixture batches using the deployed official SDK and encoder."
  require Galileo.Events
  @spec main() :: :ok
  def main do
    socket = "/tmp/overalls-trace-fixture-#{System.unique_integer([:positive])}.sock"
    System.put_env("OVERALLS_TRACE_SOCKET", socket)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    processor = Process.whereis(Overalls.Diagnostics.Processor)
    :ok = :sys.suspend(processor)
    try do
      task = Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(listener, 5000)
        body = request(connection, "")
        :ok = :gen_tcp.send(connection, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        :gen_tcp.close(connection)
        body
      end)
      for _ <- 1..128 do
        :ok =
          Galileo.Events.emit("galileo.request_denied",
            request_id: "11111111-1111-4111-8111-111111111111",
            reason: :unauthorized
          )
      end
      :ok = :sys.resume(processor)
      :ok = Overalls.Diagnostics.Processor.force_flush(%{})
      body = Task.await(task, 5000)
      File.write!(Path.join(__DIR__, "batch.hex"), Base.encode16(body, case: :lower) <> "\n")
      :ok
    after
      _ = :sys.resume(processor)
      :gen_tcp.close(listener)
      File.rm(socket)
    end
  end
  @spec request(port(), binary()) :: binary()
  defp request(connection, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: ([0-9]+)/i, headers)
        if byte_size(body) == String.to_integer(length), do: body, else: more(connection, bytes)
      [_] -> more(connection, bytes)
    end
  end
  @spec more(port(), binary()) :: binary()
  defp more(connection, bytes) do
    {:ok, next} = :gen_tcp.recv(connection, 0, 5000)
    request(connection, bytes <> next)
  end
end
Overalls.TraceSpoolFixture.main()
