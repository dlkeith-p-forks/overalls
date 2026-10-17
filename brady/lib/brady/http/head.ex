defmodule Brady.HTTP.Head do
  @moduledoc "Bounded strict HTTP/1 framing. No peer-controlled atoms or lenient framing ambiguity."
  alias Brady.Cache.Policy
  @limit 32_768
  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @hop ~w(connection keep-alive proxy-connection proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @type head :: %{
          optional(:method) => String.t(),
          optional(:target) => String.t(),
          optional(:status) => integer(),
          headers: Policy.headers(),
          body: :none | :chunked | :close | {:length, non_neg_integer()}
        }

  # @cc [owner:ghuntley,label:security] brady-http-unambiguous-framing
  # Parsing MUST bound headers, reject duplicate length/host and TE+CL, obsolete
  # folding and control characters. Extra bytes MUST remain available to the
  # body/next message; malformed framing MUST terminate this connection.
  @spec parse(binary(), :request | :response) ::
          :more | {:ok, head(), binary()} | {:error, :invalid_http}
  def parse(buffer, kind) when is_binary(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        if byte_size(buffer) <= @limit, do: :more, else: {:error, :invalid_http}

      {length, 4} when length <= @limit ->
        <<raw::binary-size(^length), _::binary-size(4), rest::binary>> = buffer

        with true <- String.valid?(raw),
             [start | lines] <- String.split(raw, "\r\n"),
             true <- length(lines) <= 100,
             {:ok, fields} <- start(start, kind),
             {:ok, headers} <- headers(lines),
             true <- valid_host?(headers, kind),
             {:ok, body} <- framing(headers, kind) do
          body =
            if Map.get(fields, :status, 0) in 100..199 or Map.get(fields, :status) in [204, 304],
              do: :none,
              else: body

          {:ok, Map.merge(fields, %{headers: headers, body: body}), rest}
        else
          _ -> {:error, :invalid_http}
        end

      _ ->
        {:error, :invalid_http}
    end
  end

  @spec request_bytes(head()) :: iodata()
  def request_bytes(head) do
    [
      head.method,
      " ",
      head.target,
      " HTTP/1.1\r\n",
      encode_headers(clean(head.headers)),
      framing_headers(head.body),
      "connection: close\r\n\r\n"
    ]
  end

  @spec response_bytes(head()) :: iodata()
  def response_bytes(head) do
    [
      "HTTP/1.1 ",
      Integer.to_string(head.status),
      " ",
      reason(head.status),
      "\r\n",
      encode_headers(clean(head.headers) |> Enum.reject(fn {key, _} -> key == "alt-svc" end)),
      framing_headers(head.body),
      "connection: close\r\n\r\n"
    ]
  end

  @spec clean(Policy.headers()) :: Policy.headers()
  def clean(headers) do
    named =
      Policy.values(headers, "connection")
      |> Enum.join(",")
      |> String.downcase()
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    Enum.reject(headers, fn {name, _} ->
      name in @hop or name in named or name == "content-length"
    end)
  end

  defp start(line, :request) do
    case String.split(line, " ") do
      [method, target, version] when version in ["HTTP/1.1", "HTTP/1.0"] ->
        if byte_size(method) in 1..32 and Regex.match?(@token, method) and
             byte_size(target) in 1..8192 and String.starts_with?(target, "/") and
             not Regex.match?(~r/[\x00-\x20\x7f]/, target),
           do: {:ok, %{method: method, target: target}},
           else: :error

      _ ->
        :error
    end
  end

  defp start(line, :response) do
    case Regex.run(~r/\AHTTP\/1\.[01] ([1-5][0-9]{2}) [\x20-\x7e]*\z/, line,
           capture: :all_but_first
         ) do
      [status] -> {:ok, %{status: String.to_integer(status)}}
      _ -> :error
    end
  end

  defp headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case String.split(line, ":", parts: 2) do
        [name, value] when byte_size(line) <= 8192 ->
          if Regex.match?(@token, name) and not Regex.match?(~r/[\x00-\x08\x0a-\x1f\x7f]/, value) do
            {:cont,
             {:ok,
              [{String.downcase(name), Regex.replace(~r/\A[ \t]+|[ \t]+\z/, value, "")} | acc]}}
          else
            {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      _ -> :error
    end
  end

  defp valid_host?(headers, :request), do: length(Policy.values(headers, "host")) == 1
  defp valid_host?(_, :response), do: true

  defp framing(headers, kind) do
    case {Policy.values(headers, "content-length"), Policy.values(headers, "transfer-encoding")} do
      {[], []} ->
        {:ok, if(kind == :request, do: :none, else: :close)}

      {[], [encoding]} ->
        if String.downcase(encoding) == "chunked", do: {:ok, :chunked}, else: :error

      {[length], []} ->
        if Regex.match?(~r/\A[0-9]{1,19}\z/, length),
          do: {:ok, {:length, String.to_integer(length)}},
          else: :error

      _ ->
        :error
    end
  end

  defp encode_headers(headers),
    do: Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

  defp framing_headers({:length, size}), do: ["content-length: ", Integer.to_string(size), "\r\n"]
  defp framing_headers(:chunked), do: "transfer-encoding: chunked\r\n"
  defp framing_headers(_), do: []
  defp reason(200), do: "OK"
  defp reason(206), do: "Partial Content"
  defp reason(400), do: "Bad Request"
  defp reason(403), do: "Forbidden"
  defp reason(416), do: "Range Not Satisfiable"
  defp reason(502), do: "Bad Gateway"
  defp reason(503), do: "Service Unavailable"
  defp reason(_), do: "Response"
end
