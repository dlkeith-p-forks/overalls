defmodule OverallsProtocol.Terminal do
  @moduledoc "Bounded terminal stream v2: binary frames plus closed-schema control messages."
  @maximum 9_223_372_036_854_775_807
  @type uuid :: OverallsProtocol.uuid()
  @type failure :: {:error, :invalid_message | :unsupported_version}
  @type mode :: :rw | :ro
  @type data_frame :: %{channel: pos_integer(), sequence: pos_integer(), bytes: binary()}
  @type control_type ::
          :hello
          | :heartbeat
          | :heartbeat_reply
          | :input_ack
          | :output_ack
          | :users
          | :users_listed
          | :hello_response
          | :create
          | :created
          | :attach
          | :attached
          | :channel_close
          | :listing
          | :listed
          | :kill
          | :killed
          | :resize
          | :closed
          | :boot_log
          | :boot_log_data
          | :creation_query
          | :creation_status
          | :creation_cancel
          | :creation_cancelled
          | :android_display_open
          | :android_display_opened
          | :android_display_close
  @type control_frame :: %{channel: 0, message: control_message()}
  @type control_message ::
          %{type: :users, vm_id: uuid(), placement_id: uuid(), execution_epoch: pos_integer()}
          | %{type: :users_listed, vm_id: uuid(), users: [String.t()]}
          | %{
              type: :input_ack | :output_ack,
              channel: pos_integer(),
              frames: non_neg_integer(),
              bytes: non_neg_integer()
            }
          | %{type: :heartbeat | :heartbeat_reply, sequence: pos_integer()}
          | %{
              type: :killed,
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer(),
              guest_session_id: pos_integer(),
              ok: boolean()
            }
          | %{
              type: :creation_query | :creation_cancel,
              request_id: uuid(),
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer()
            }
          | %{
              type: :creation_status,
              request_id: uuid(),
              state: :running | :exited | :unknown,
              guest_session_id: pos_integer() | nil
            }
          | %{type: :creation_cancelled, request_id: uuid(), ok: boolean()}
          | %{
              type: :android_display_open,
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer(),
              generation: pos_integer(),
              mode: :viewer | :controller,
              ticket: String.t(),
              channel: pos_integer()
            }
          | %{
              type: :android_display_opened,
              channel: pos_integer(),
              generation: pos_integer(),
              ok: boolean(),
              reason: :display_unavailable | :fenced | :controller_busy | nil
            }
          | %{type: :android_display_close, channel: pos_integer()}
          | %{
              type: :hello,
              host_id: uuid(),
              session_id: uuid(),
              epoch: pos_integer()
            }
          | %{
              type: :hello_response,
              interval_ms: 1000
            }
          | %{
              type: :create,
              request_id: uuid(),
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer(),
              mode: mode(),
              user: String.t(),
              term: String.t(),
              cols: pos_integer(),
              rows: pos_integer(),
              channel: pos_integer()
            }
          | %{
              type: :created,
              request_id: uuid(),
              ok: boolean(),
              channel: pos_integer(),
              guest_session_id: pos_integer() | nil,
              reason: :dial_failed | :rejected | :limit | nil
            }
          | %{
              type: :attach,
              cols: non_neg_integer(),
              rows: non_neg_integer(),
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer(),
              guest_session_id: pos_integer(),
              mode: mode(),
              cursor: non_neg_integer(),
              channel: pos_integer()
            }
          | %{
              type: :attached,
              replay_bytes: non_neg_integer(),
              channel: pos_integer(),
              ok: boolean(),
              guest_session_id: pos_integer() | nil,
              from: non_neg_integer() | nil,
              reason: :dial_failed | :rejected | :not_found | :fenced | nil
            }
          | %{
              type: :channel_close,
              channel: pos_integer()
            }
          | %{
              type: :boot_log,
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer(),
              cursor: non_neg_integer()
            }
          | %{
              type: :boot_log_data,
              vm_id: uuid(),
              next: non_neg_integer(),
              bytes: binary()
            }
          | %{
              type: :listing,
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer()
            }
          | %{
              type: :listed,
              vm_id: uuid(),
              sessions: [guest_session()]
            }
          | %{
              type: :kill,
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer(),
              guest_session_id: pos_integer()
            }
          | %{
              type: :resize,
              vm_id: uuid(),
              placement_id: uuid(),
              execution_epoch: pos_integer(),
              guest_session_id: pos_integer(),
              cols: pos_integer(),
              rows: pos_integer()
            }
          | %{
              type: :closed,
              channel: pos_integer(),
              reason: :session_exit | :dial_failed | :killed | :fenced
            }
  @type guest_session :: %{
          guest_session_id: pos_integer(),
          user: String.t(),
          cols: pos_integer(),
          rows: pos_integer(),
          viewers: non_neg_integer(),
          alive: boolean(),
          created_ms: non_neg_integer(),
          last_ms: non_neg_integer()
        }

  @frame_header 15
  @data 1
  @control 2
  @max_frame_payload 65_535
  @max_control_payload 65_535
  @max_listing 64

  # @cc [owner:ghuntley,label:protocol] frame-codec-bounds
  # encode_data_frame/3 and encode_control_frame/1 MUST emit the 15-byte
  # header [channel u32 BE][type u8][sequence u64 BE][len u16 BE] followed by
  # the payload, and data payloads MUST NOT exceed 65,535 bytes. decode_frame/1
  # MUST reject short, oversized, or trailing bytes and never allocate more
  # than the declared payload length.
  @spec encode_data_frame(pos_integer(), pos_integer(), binary()) :: binary()
  def encode_data_frame(channel, sequence, bytes)
      when is_integer(channel) and channel > 0 and is_integer(sequence) and sequence > 0 and
             is_binary(bytes) and byte_size(bytes) <= @max_frame_payload do
    <<channel::32, @data, sequence::64, byte_size(bytes)::16>> <> bytes
  end

  @spec encode_control_frame(control_message()) :: binary()
  def encode_control_frame(message) do
    payload = JSON.encode!(encode_message(message))
    <<0::32, @control, 0::64, byte_size(payload)::16>> <> payload
  end

  @spec decode_frame(binary()) :: {:ok, data_frame() | control_frame()} | failure() | :partial
  def decode_frame(<<channel::32, kind, sequence::64, length::16, payload::binary>>)
      when byte_size(payload) == length and length <= @max_frame_payload do
    case kind do
      @data when channel > 0 and sequence > 0 ->
        {:ok, %{channel: channel, sequence: sequence, bytes: payload}}

      @control when channel == 0 and sequence == 0 and length <= @max_control_payload ->
        case JSON.decode(payload) do
          {:ok, value} when is_map(value) ->
            case decode_control(value) do
              {:ok, message} -> {:ok, %{channel: 0, message: message}}
              error -> error
            end

          _ ->
            {:error, :invalid_message}
        end

      _ ->
        {:error, :invalid_message}
    end
  end

  def decode_frame(<<_channel::32, _kind, _sequence::64, length::16, rest::binary>>)
      when byte_size(rest) < length do
    :partial
  end

  def decode_frame(body) when is_binary(body) and byte_size(body) < @frame_header, do: :partial
  def decode_frame(_), do: {:error, :invalid_message}

  @doc "Decode one frame from the start of a buffer and retain any following frames."
  @spec decode_frame_prefix(binary()) ::
          {:ok, data_frame() | control_frame(), binary()} | failure() | :partial
  def decode_frame_prefix(body) when is_binary(body) do
    case body do
      <<_channel::32, _kind, _sequence::64, length::16, rest::binary>>
      when byte_size(rest) >= length ->
        consumed = @frame_header + length
        <<frame::binary-size(^consumed), trailing::binary>> = body

        case decode_frame(frame) do
          {:ok, decoded} -> {:ok, decoded, trailing}
          error -> error
        end

      _ when byte_size(body) < @frame_header ->
        :partial

      <<_channel::32, _kind, _sequence::64, length::16, rest::binary>>
      when byte_size(rest) < length ->
        :partial

      _ ->
        {:error, :invalid_message}
    end
  end

  @spec frame_consumed(binary()) :: non_neg_integer()
  def frame_consumed(<<_channel::32, _kind, _sequence::64, length::16, _rest::binary>>),
    do: @frame_header + length

  @spec max_frame_payload() :: pos_integer()
  def max_frame_payload, do: @max_frame_payload

  defp decode_control(%{"version" => 2} = value), do: message(value)
  defp decode_control(%{"version" => _}), do: {:error, :unsupported_version}
  defp decode_control(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:security] control-placement-authority
  # Every VM-scoped control MUST carry an explicit placement ID and positive
  # execution epoch; channel numbers MUST be positive and distinct per stream.
  defp message(value) when is_map(value) do
    case Map.fetch(value, "type") do
      {:ok, type} when is_binary(type) ->
        value |> Map.delete("version") |> Map.delete("type") |> control(type)

      _ ->
        {:error, :invalid_message}
    end
  end

  defp control(value, "hello") do
    with {:ok, result} <-
           object(value,
             host_id: :uuid,
             session_id: :uuid,
             epoch: :positive
           ) do
      {:ok,
       %{
         type: :hello,
         host_id: result.host_id,
         session_id: result.session_id,
         epoch: result.epoch
       }}
    end
  end

  defp control(value, "hello_response") do
    with {:ok, result} <- object(value, interval_ms: {:one_of, [1000]}) do
      {:ok, %{type: :hello_response, interval_ms: result.interval_ms}}
    end
  end

  defp control(value, type) when type in ["input_ack", "output_ack"] do
    with {:ok, result} <- object(value, channel: :positive, frames: :counter, bytes: :counter) do
      {:ok, Map.put(result, :type, if(type == "input_ack", do: :input_ack, else: :output_ack))}
    end
  end

  defp control(value, type) when type in ["heartbeat", "heartbeat_reply"] do
    with {:ok, result} <- object(value, sequence: :positive) do
      {:ok,
       Map.put(result, :type, if(type == "heartbeat", do: :heartbeat, else: :heartbeat_reply))}
    end
  end

  defp control(value, type) when type in ["creation_query", "creation_cancel"] do
    with {:ok, result} <-
           object(value,
             request_id: :uuid,
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive
           ) do
      {:ok,
       Map.put(
         result,
         :type,
         if(type == "creation_query", do: :creation_query, else: :creation_cancel)
       )}
    end
  end

  defp control(value, "creation_status") do
    with {:ok, result} <-
           object(value,
             request_id: :uuid,
             state: {:enum, [:running, :exited, :unknown]},
             guest_session_id: {:nullable, :positive}
           ),
         true <-
           (result.state == :unknown and is_nil(result.guest_session_id)) or
             (result.state in [:running, :exited] and is_integer(result.guest_session_id)) do
      {:ok, Map.put(result, :type, :creation_status)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp control(value, "creation_cancelled") do
    with {:ok, result} <- object(value, request_id: :uuid, ok: :boolean),
         do: {:ok, Map.put(result, :type, :creation_cancelled)}
  end

  defp control(value, "android_display_open") do
    with {:ok, result} <-
           object(value,
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive,
             generation: :positive,
             mode: {:enum, [:viewer, :controller]},
             ticket: {:string, 1, 4096},
             channel: :positive
           ) do
      {:ok, struct_from(:android_display_open, result)}
    end
  end

  defp control(value, "android_display_opened") do
    with {:ok, result} <-
           object(value,
             channel: :positive,
             generation: :positive,
             ok: :boolean,
             reason: {:nullable, {:enum, [:display_unavailable, :fenced, :controller_busy]}}
           ),
         true <- coherent_android_opened?(result) do
      {:ok, struct_from(:android_display_opened, result)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp control(value, "android_display_close") do
    with {:ok, result} <- object(value, channel: :positive),
         do: {:ok, struct_from(:android_display_close, result)}
  end

  defp control(value, "create") do
    with {:ok, result} <-
           object(value,
             request_id: :uuid,
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive,
             mode: {:enum, [:rw, :ro]},
             user: {:string, 1, 64},
             term: {:string, 1, 32},
             cols: {:integer, 1, 4096},
             rows: {:integer, 1, 512},
             channel: :positive
           ) do
      {:ok, struct_from(:create, result)}
    end
  end

  defp control(value, "created") do
    with {:ok, result} <-
           object(value,
             request_id: :uuid,
             ok: :boolean,
             channel: :positive,
             guest_session_id: {:nullable, :positive},
             reason: {:nullable, {:enum, [:dial_failed, :rejected, :limit]}}
           ),
         true <- coherent_created?(result) do
      {:ok, struct_from(:created, result)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp control(value, "attach") do
    with {:ok, result} <-
           object(value,
             cols: {:integer, 0, 4096},
             rows: {:integer, 0, 512},
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive,
             guest_session_id: :positive,
             mode: {:enum, [:rw, :ro]},
             cursor: :counter,
             channel: :positive
           ) do
      {:ok, struct_from(:attach, result)}
    end
  end

  defp control(value, "attached") do
    with {:ok, result} <-
           object(value,
             replay_bytes: {:integer, 0, 8_388_608},
             channel: :positive,
             ok: :boolean,
             guest_session_id: {:nullable, :positive},
             from: {:nullable, :counter},
             reason: {:nullable, {:enum, [:dial_failed, :rejected, :not_found, :fenced]}}
           ),
         true <- coherent_attached?(result) do
      {:ok, struct_from(:attached, result)}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp control(value, "channel_close") do
    with {:ok, result} <- object(value, channel: :positive) do
      {:ok, struct_from(:channel_close, result)}
    end
  end

  defp control(value, "boot_log") do
    with {:ok, result} <-
           object(value,
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive,
             cursor: :counter
           ) do
      {:ok, struct_from(:boot_log, result)}
    end
  end

  defp control(value, "boot_log_data") do
    with {:ok, result} <-
           object(value, vm_id: :uuid, next: :counter, bytes: {:bytes, 0, 16_384}) do
      {:ok, struct_from(:boot_log_data, result)}
    end
  end

  defp control(value, "listing") do
    with {:ok, result} <-
           object(value, vm_id: :uuid, placement_id: :uuid, execution_epoch: :positive) do
      {:ok, struct_from(:listing, result)}
    end
  end

  defp control(value, "users") do
    with {:ok, result} <-
           object(value, vm_id: :uuid, placement_id: :uuid, execution_epoch: :positive),
         do: {:ok, struct_from(:users, result)}
  end

  defp control(value, "users_listed") do
    with {:ok, result} <- object(value, vm_id: :uuid, users: {:collection, &user_name/1, 64}),
         do: {:ok, struct_from(:users_listed, result)}
  end

  defp control(value, "listed") do
    with {:ok, result} <-
           object(value,
             vm_id: :uuid,
             sessions: {:collection, &guest_session/1, @max_listing}
           ) do
      {:ok, struct_from(:listed, result)}
    end
  end

  defp control(value, "kill") do
    with {:ok, result} <-
           object(value,
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive,
             guest_session_id: :positive
           ) do
      {:ok, struct_from(:kill, result)}
    end
  end

  defp control(value, "killed") do
    with {:ok, result} <-
           object(value,
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive,
             guest_session_id: :positive,
             ok: :boolean
           ) do
      {:ok, struct_from(:killed, result)}
    end
  end

  defp control(value, "resize") do
    with {:ok, result} <-
           object(value,
             vm_id: :uuid,
             placement_id: :uuid,
             execution_epoch: :positive,
             guest_session_id: :positive,
             cols: {:integer, 1, 4096},
             rows: {:integer, 1, 512}
           ) do
      {:ok, struct_from(:resize, result)}
    end
  end

  defp control(value, "closed") do
    with {:ok, result} <-
           object(value,
             channel: :positive,
             reason: {:enum, [:session_exit, :dial_failed, :killed, :fenced]}
           ) do
      {:ok, struct_from(:closed, result)}
    end
  end

  defp control(_, _), do: {:error, :invalid_message}

  defp coherent_android_opened?(%{ok: true, reason: nil}), do: true
  defp coherent_android_opened?(%{ok: false, reason: reason}) when reason != nil, do: true
  defp coherent_android_opened?(_), do: false

  defp user_name(value) when is_binary(value) and byte_size(value) in 1..64 do
    if String.valid?(value) and not String.contains?(value, [<<0>>, "\n", "\r"]),
      do: {:ok, value},
      else: {:error, :invalid_message}
  end

  defp user_name(_), do: {:error, :invalid_message}

  defp collection_identity(%{guest_session_id: id}), do: id
  defp collection_identity(name) when is_binary(name), do: name

  defp coherent_attached?(%{ok: true} = value),
    do: is_integer(value.guest_session_id) and is_integer(value.from) and value.reason == nil

  defp coherent_attached?(%{ok: false} = value),
    do:
      value.guest_session_id == nil and value.from == nil and
        value.replay_bytes == 0 and value.reason in [:dial_failed, :rejected, :not_found, :fenced]

  defp coherent_created?(%{ok: true} = value),
    do: is_integer(value.guest_session_id) and value.reason == nil

  defp coherent_created?(%{ok: false} = value),
    do: value.guest_session_id == nil and value.reason in [:dial_failed, :rejected, :limit]

  defp guest_session(value) do
    with {:ok, result} <-
           object(value,
             guest_session_id: :positive,
             user: {:string, 1, 64},
             cols: {:integer, 1, 4096},
             rows: {:integer, 1, 512},
             viewers: {:integer, 0, 4096},
             alive: :boolean,
             created_ms: :counter,
             last_ms: :counter
           ) do
      {:ok, result}
    end
  end

  defp struct_from(kind, result), do: Map.put(result, :type, kind)

  defp object(value, fields) when is_map(value) and map_size(value) == length(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, type}, {:ok, result} ->
      with {:ok, wire} <- Map.fetch(value, Atom.to_string(key)),
           {:ok, decoded} <- decode(wire, type) do
        {:cont, {:ok, Map.put(result, key, decoded)}}
      else
        _ -> {:halt, {:error, :invalid_message}}
      end
    end)
  end

  defp object(_, _), do: {:error, :invalid_message}

  defp decode(nil, {:nullable, _}), do: {:ok, nil}
  defp decode(value, {:nullable, type}), do: decode(value, type)
  defp decode(value, :uuid), do: checked(value, OverallsProtocol.uuid?(value))
  defp decode(value, :positive), do: decode(value, {:integer, 1, @maximum})
  defp decode(value, :counter), do: decode(value, {:integer, 0, @maximum})
  defp decode(value, :boolean), do: checked(value, is_boolean(value))

  defp decode(value, {:integer, minimum, maximum}),
    do: checked(value, is_integer(value) and value >= minimum and value <= maximum)

  defp decode(value, {:one_of, values}), do: checked(value, value in values)

  defp decode(value, {:string, minimum, maximum}),
    do:
      checked(
        value,
        is_binary(value) and byte_size(value) >= minimum and byte_size(value) <= maximum
      )

  defp decode(value, {:bytes, minimum, maximum}) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) >= minimum and byte_size(bytes) <= maximum ->
        {:ok, bytes}

      _ ->
        {:error, :invalid_message}
    end
  end

  defp decode(_, {:bytes, _, _}), do: {:error, :invalid_message}

  defp decode(value, {:enum, atoms}) do
    case Enum.find(atoms, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_message}
      atom -> {:ok, atom}
    end
  end

  defp decode(values, {:collection, decoder, maximum})
       when is_list(values) and length(values) <= maximum do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case decoder.(value) do
        {:ok, decoded} ->
          if Enum.any?(result, &(collection_identity(&1) == collection_identity(decoded))),
            do: {:halt, {:error, :invalid_message}},
            else: {:cont, {:ok, [decoded | result]}}

        _ ->
          {:halt, {:error, :invalid_message}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp decode(_, {:collection, _, _}), do: {:error, :invalid_message}

  defp checked(value, true), do: {:ok, value}
  defp checked(_, false), do: {:error, :invalid_message}

  defp encode_message(%{type: kind} = value) do
    value
    |> Map.delete(:type)
    |> Map.new(fn
      {:bytes, bytes} when is_binary(bytes) -> {"bytes", Base.encode64(bytes)}
      {key, value} -> {Atom.to_string(key), encode_value(value)}
    end)
    |> Map.put("type", Atom.to_string(kind))
    |> Map.put("version", 2)
  end

  defp encode_value(value) when value in [nil, true, false], do: value
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)

  defp encode_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {Atom.to_string(k), encode_value(v)} end)

  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value), do: value
end
