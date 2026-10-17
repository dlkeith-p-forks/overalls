defmodule Lilly.VM.API do
  @moduledoc "Bounded private Unix-socket Firecracker requests. Responses never enter logs."
  @limit 16_384
  # @cc [owner:ghuntley,label:protocol] vmm-readiness-matches-id-version
  # API.running?/2 MUST require HTTP 200 with the requested VM ID, Running state and supported
  # Firecracker 1.16.1 version. Oversized, ambiguous, truncated or invalid replies must not
  # establish readiness.
  @spec running?(Path.t(), String.t()) :: boolean()
  def running?(path, id) do
    case request(path, "GET", "/", "") do
      {:ok, 200, body} ->
        case JSON.decode(body) do
          {:ok, %{"id" => ^id, "state" => "Running", "vmm_version" => "1.16.1"}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # @cc [owner:ghuntley,label:assumption;recovery] shutdown-response-is-not-stop-proof
  # shutdown/1 reports only acceptance of SendCtrlAltDel (HTTP 204). Its caller MUST still prove
  # the unit/cgroup stopped before treating compute as empty or removing resources.
  @spec shutdown(Path.t()) :: :ok | {:error, :vmm_api_unavailable}
  def shutdown(path) do
    case request(path, "PUT", "/actions", ~s({"action_type":"SendCtrlAltDel"})) do
      {:ok, 204, _} -> :ok
      _ -> {:error, :vmm_api_unavailable}
    end
  end

  defp request(path, method, route, body) do
    with {:ok, socket} <-
           Lilly.Host.Sockets.connect_local(
             path,
             [:binary, active: false, packet: :raw, send_timeout: 1000, send_timeout_close: true],
             1000
           ) do
      try do
        with :ok <-
               :gen_tcp.send(socket, [
                 method,
                 " ",
                 route,
                 " HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ",
                 Integer.to_string(byte_size(body)),
                 "\r\nConnection: close\r\n\r\n",
                 body
               ]),
             do: receive_response(socket, "", System.monotonic_time(:millisecond) + 2000)
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp receive_response(socket, bytes, deadline) do
    case parse(bytes) do
      :more ->
        with remaining when remaining > 0 <- deadline - System.monotonic_time(:millisecond),
             {:ok, chunk} <- :gen_tcp.recv(socket, 0, remaining),
             true <- byte_size(bytes) + byte_size(chunk) <= @limit,
             do: receive_response(socket, bytes <> chunk, deadline),
             else: (_ -> :error)

      result ->
        result
    end
  end

  defp parse(bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [_] ->
        :more

      [head, body] ->
        with [status | lines] <- String.split(head, "\r\n"),
             [_, code, _] <- String.split(status, " ", parts: 3),
             {code, ""} <- Integer.parse(code),
             lengths =
               for(
                 line <- lines,
                 String.starts_with?(String.downcase(line), "content-length:"),
                 do: line |> String.split(":", parts: 2) |> List.last() |> String.trim()
               ),
             {:ok, length} <- content_length(code, lengths),
             true <- length in 0..@limit do
          cond do
            byte_size(body) < length -> :more
            byte_size(body) == length -> {:ok, code, body}
            true -> :error
          end
        else
          _ -> :error
        end
    end
  end

  defp content_length(204, []), do: {:ok, 0}

  defp content_length(_code, [value]) do
    case Integer.parse(value) do
      {length, ""} -> {:ok, length}
      _ -> :error
    end
  end

  defp content_length(_, _), do: :error
end
