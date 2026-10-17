defmodule Brady.Cache do
  @moduledoc "Cache policy and storage boundary. Cache outages never grant network bypass."
  alias Brady.Cache.{Policy, Range, Store}
  alias Brady.HTTP.Head

  @variants [
    [],
    ["accept"],
    ["accept-encoding"],
    ["accept-language"],
    ["accept", "accept-encoding"],
    ["accept", "accept-language"],
    ["accept-encoding", "accept-language"],
    ["accept", "accept-encoding", "accept-language"]
  ]

  # @cc [owner:ghuntley,label:security] brady-cache-range-read-only-exception
  # Lookup may reuse ranges only from fresh complete public representations.
  # Removing Range/If-Range for the anonymity check MUST NOT remove other privacy
  # refusals, and the original headers MUST determine range/validator selection.
  # This lookup exception MUST NOT make range responses eligible for publication.
  @spec lookup(Store.server(), Policy.request(), integer()) ::
          :miss | {:hit, reference(), map(), non_neg_integer(), non_neg_integer()}
  def lookup(server, request, now) do
    anonymous = %{
      request
      | headers:
          Enum.reject(request.headers, fn {key, _} ->
            String.downcase(key) in ["range", "if-range"]
          end)
    }

    if Policy.eligible?(anonymous) do
      Enum.reduce_while(@variants, :miss, fn vary, _ ->
        case safe(fn -> Store.open(server, Policy.key(anonymous, vary), now) end, :miss) do
          {:ok, ref, metadata, size} ->
            case response(request, metadata, size, now) do
              {:ok, head, offset, length} ->
                {:halt, {:hit, ref, head, offset, length}}

              _ ->
                close(server, ref)
                {:cont, :miss}
            end

          _ ->
            {:cont, :miss}
        end
      end)
    else
      :miss
    end
  end

  @spec begin_write(Store.server(), Policy.request(), Head.head(), integer(), integer()) ::
          {:ok, reference()} | :bypass
  def begin_write(server, request, %{body: framing} = head, sent, received)
      when framing == :chunked or (is_tuple(framing) and elem(framing, 0) == :length) do
    size = if framing == :chunked, do: :unknown, else: elem(framing, 1)

    with {:ok, policy} <- Policy.admit(request, head.status, head.headers, sent, received) do
      metadata = %{
        "stored_at" => policy.stored_at,
        "expires_at" => policy.expires_at,
        "initial_age" => policy.initial_age,
        "headers" => Enum.map(Head.clean(policy.headers), fn {k, v} -> [k, v] end)
      }

      safe(fn -> Store.begin_write(server, policy.key, metadata, size) end, :bypass)
    else
      _ -> :bypass
    end
  end

  def begin_write(_, _, _, _, _), do: :bypass

  @spec append(Store.server(), reference(), binary()) :: :ok | :bypass
  def append(server, ref, bytes), do: safe(fn -> Store.append(server, ref, bytes) end, :bypass)
  # @cc [owner:ghuntley,label:recovery] brady-cache-validated-completion
  # Callers MUST commit unknown-length writes only after the HTTP parser confirms
  # terminal framing and client delivery. Any trailers MUST abort before commit.
  @spec commit(Store.server(), reference()) :: :ok | :bypass
  def commit(server, ref), do: safe(fn -> Store.commit(server, ref) end, :bypass)
  @spec abort(Store.server(), reference()) :: :ok
  def abort(server, ref), do: safe(fn -> Store.abort(server, ref) end, :ok)
  @spec close(Store.server(), reference()) :: :ok
  def close(server, ref), do: safe(fn -> Store.close(server, ref) end, :ok)

  @spec stream(
          Store.server(),
          reference(),
          non_neg_integer(),
          non_neg_integer(),
          Brady.HTTP.Stream.sink()
        ) :: :ok | {:error, :storage | :transport}
  def stream(_, _, _, 0, _), do: :ok

  def stream(server, ref, offset, remaining, sink) do
    with {:ok, bytes} when byte_size(bytes) > 0 <-
           safe(
             fn -> Store.read(server, ref, offset, min(remaining, 65_536)) end,
             {:error, :storage}
           ),
         :ok <- sink.(bytes) do
      stream(server, ref, offset + byte_size(bytes), remaining - byte_size(bytes), sink)
    else
      {:error, :transport} -> {:error, :transport}
      _ -> {:error, :storage}
    end
  end

  defp response(request, metadata, size, now) do
    headers = Enum.map(metadata["headers"], fn [key, value] -> {key, value} end)
    age = metadata["initial_age"] + now - metadata["stored_at"]

    headers =
      Enum.reject(headers, fn {name, _} -> name in ["age", "content-range", "alt-svc"] end) ++
        [{"age", Integer.to_string(age)}]

    case Range.select(request.headers, headers, size) do
      :full ->
        {:ok, %{status: 200, headers: headers, body: {:length, size}}, 0, size}

      {:partial, offset, length} ->
        headers = headers ++ [{"content-range", "bytes #{offset}-#{offset + length - 1}/#{size}"}]
        {:ok, %{status: 206, headers: headers, body: {:length, length}}, offset, length}

      :unsatisfiable ->
        {:ok, %{status: 416, headers: [{"content-range", "bytes */#{size}"}], body: {:length, 0}},
         0, 0}

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  # @cc [owner:ghuntley,label:recovery] brady-cache-errors-remain-local
  # A missing/crashed cache MUST become a miss or abandoned write without
  # exposing exception messages. The caller MUST still use the admitted proxy
  # upstream path; this boundary MUST NOT provide a direct guest fallback.
  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end
end
