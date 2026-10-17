defmodule Brady.Log do
  @moduledoc "Closed structured events. Arbitrary Logger messages and metadata are never serialized."
  require Brady.Events
  @ids [:host_id, :vm_id, :placement_id, :owner_id, :request_id]
  @numbers [
    :execution_epoch,
    :generation,
    :status,
    :port,
    :bytes_received,
    :bytes_sent,
    :duration_us
  ]
  @enums %{
    event: [:request, :runtime_event],
    attribution: [:resolved, :unresolved],
    protocol: [:http, :https, :tunnel],
    cache: [:hit, :miss, :bypass, :failed],
    cache_write: [:published, :abandoned, :not_attempted],
    reason: [
      :ok,
      :policy,
      :upstream,
      :tls,
      :timeout,
      :capacity,
      :storage,
      :invalid_request,
      :internal,
      :transport,
      :closed
    ],
    slo_admitted: [:yes]
  }
  @methods ~w(GET HEAD POST PUT DELETE OPTIONS PATCH CONNECT TRACE)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @spec request(map()) :: :ok
  def request(fields) do
    event = sanitize(Map.put(fields, :event, :request))
    Brady.Metrics.request(event)

    Brady.Events.emit("brady.request_completed",
      host_id: event[:host_id],
      vm_id: event[:vm_id],
      placement_id: event[:placement_id],
      owner_id: event[:owner_id],
      request_id: event[:request_id],
      execution_epoch: event[:execution_epoch],
      generation: event[:generation],
      status: event[:status],
      port: event[:port],
      bytes_received: event[:bytes_received],
      bytes_sent: event[:bytes_sent],
      duration_us: event[:duration_us],
      attribution: event[:attribution],
      protocol: event[:protocol],
      cache: event[:cache],
      cache_write: event[:cache_write],
      reason: event[:reason],
      slo_admitted: event[:slo_admitted],
      method: method(event[:method])
    )
  end

  # @cc [owner:ghuntley,label:security] brady-log-closed-values
  # sanitize/1 MUST discard unknown keys and values, accepting identifiers only
  # as UUIDs, numeric counters only as bounded nonnegative integers, and enums
  # only from fixed lists. It MUST NOT stringify untrusted terms.
  @spec sanitize(term()) :: map()
  def sanitize(fields) when is_map(fields) do
    Map.new(
      Enum.flat_map(fields, fn {key, value} ->
        if valid?(key, value), do: [{key, value}], else: []
      end)
    )
  end

  def sanitize(_), do: %{}

  # @cc [owner:ghuntley,label:security] brady-formatter-ignores-runtime-payload
  # The formatter MUST ignore the entire message/report and all metadata outside
  # the reviewed catalog branch and exact validated trace/span IDs, including
  # crash reasons, process state and dependency messages.

  # @cc [owner:ghuntley,label:security] brady-formatter-reviewed-events
  # A catalogued event MUST serialize only when the metadata :event name and the
  # message text both match the reviewed catalog and every declared metadata
  # value passes its catalogued shape. Anything else MUST fall back to the
  # redacted runtime_event path; no undeclared or unvalidated value may be
  # serialized.
  @spec format(map(), term()) :: iodata()
  def format(event, _config) do
    fields = reviewed(event) || %{event: :runtime_event}

    fields =
      Map.merge(fields, Overalls.Diagnostics.Context.log_context(Map.get(event, :meta, %{})))

    [JSON.encode!(fields), "\n"]
  end

  defp reviewed(%{msg: msg, meta: %{event: name} = meta}) when is_binary(name) do
    case message_text(msg) do
      nil ->
        nil

      text ->
        case Map.get(Brady.Events.__catalog__(), name) do
          %{message: ^text, metadata: declared} -> validated(name, meta, declared)
          _ -> nil
        end
    end
  end

  defp reviewed(_), do: nil

  defp message_text({:string, text}) when is_binary(text), do: text
  defp message_text(text) when is_binary(text), do: text
  defp message_text(_), do: nil

  defp validated(name, meta, declared) do
    if Enum.all?(declared, fn {key, type} -> shape?(type, Map.get(meta, key)) end) do
      fields =
        declared
        |> Enum.flat_map(fn {key, _type} ->
          case Map.get(meta, key) do
            nil -> []
            value -> [{key, value}]
          end
        end)
        |> Map.new()

      Map.put(fields, :event, name)
    else
      nil
    end
  end

  defp shape?({_type, :optional}, nil), do: true
  defp shape?({type, :optional}, value), do: shape?(type, value)

  defp shape?({:enum, values}, value), do: value in values
  defp shape?(:atom, value), do: is_atom(value)
  defp shape?(:int64, value), do: is_integer(value) and value in 0..9_007_199_254_740_991

  defp shape?(:int, value),
    do: is_integer(value) and value >= 0 and value <= 2_147_483_647

  defp shape?(:uuid, value),
    do: is_binary(value) and byte_size(value) == 36 and Regex.match?(@uuid, value)

  defp shape?(_, _), do: false

  defp valid?(key, value) when key in @ids,
    do: is_binary(value) and byte_size(value) == 36 and Regex.match?(@uuid, value)

  defp valid?(key, value) when key in @numbers,
    do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991

  defp valid?(:method, value), do: value in @methods
  defp valid?(key, value), do: value in Map.get(@enums, key, [])
  @spec method(term()) :: atom() | nil
  defp method(value) do
    %{
      "GET" => :get,
      "HEAD" => :head,
      "POST" => :post,
      "PUT" => :put,
      "DELETE" => :delete,
      "OPTIONS" => :options,
      "PATCH" => :patch,
      "CONNECT" => :connect,
      "TRACE" => :trace
    }[value]
  end
end
