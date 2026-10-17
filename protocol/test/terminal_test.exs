defmodule OverallsProtocol.TerminalTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Terminal

  @id "8f14e45f-ceea-4267-af66-d3f99b7f0b6f"
  @id2 "9c83b4a1-1f7a-4bd2-9c4a-64c69fd3ba2e"
  @id3 "0dd0e1a2-6bd6-4a45-9db2-5de49a7e8b3c"
  @hex_chars Enum.concat(?a..?f, ?0..?9)
  @control_types ~w(hello hello_response heartbeat heartbeat_reply input_ack output_ack users users_listed create created attach attached channel_close listing listed kill killed resize closed boot_log boot_log_data creation_query creation_status creation_cancel creation_cancelled)a

  property "data frames round trip exactly" do
    check all(
            triplet <-
              gen all(
                    channel <- positive_integer(),
                    sequence <- positive_integer(),
                    length <- integer(0..4096),
                    bytes <- binary(length: length)
                  ) do
                {channel, sequence, bytes}
              end,
            max_runs: 300
          ) do
      {channel, sequence, bytes} = triplet
      wire = Terminal.encode_data_frame(channel, sequence, bytes)

      assert {:ok, %{channel: ^channel, sequence: ^sequence, bytes: ^bytes}} =
               Terminal.decode_frame(wire)

      assert Terminal.frame_consumed(wire) == byte_size(wire)
    end
  end

  property "control messages round trip through frames" do
    check all(message <- control_message_gen(), max_runs: 300) do
      wire = Terminal.encode_control_frame(message)
      assert {:ok, %{channel: 0, message: decoded}} = Terminal.decode_frame(wire)
      assert decoded == message
    end
  end

  test "control generators cover every closed schema" do
    assert Enum.sort(Map.keys(control_message_generators())) == Enum.sort(@control_types)
  end

  property "closed control schemas reject unknown fields" do
    check all(message <- control_message_gen(), max_runs: 300) do
      wire = Terminal.encode_control_frame(message)
      <<0::32, 2, 0::64, length::16, payload::binary-size(length)>> = wire
      value = payload |> JSON.decode!() |> Map.put("unknown", true)

      assert {:error, :invalid_message} = control_json(value)
    end
  end

  test "prefix decoding preserves coalesced following frames" do
    first = Terminal.encode_data_frame(7, 1, "first")
    second = Terminal.encode_data_frame(7, 2, "second")

    assert {:ok, %{channel: 7, sequence: 1, bytes: "first"}, ^second} =
             Terminal.decode_frame_prefix(first <> second)

    assert {:ok, %{channel: 7, sequence: 2, bytes: "second"}, <<>>} =
             Terminal.decode_frame_prefix(second)

    assert {:error, :invalid_message} = Terminal.decode_frame(first <> second)
  end

  property "truncated frames are partial, never invalid" do
    check all(
            triplet <-
              gen all(
                    channel <- integer(1..100),
                    sequence <- positive_integer(),
                    bytes <- binary(min_length: 1, max_length: 512)
                  ) do
                {channel, sequence, bytes}
              end,
            cut <- integer(0..14),
            max_runs: 200
          ) do
      {channel, sequence, bytes} = triplet
      wire = Terminal.encode_data_frame(channel, sequence, bytes)
      assert :partial = Terminal.decode_frame(binary_part(wire, 0, cut))
    end
  end

  property "oversized declared lengths are rejected" do
    check all(
            channel <- integer(1..100),
            sequence <- positive_integer(),
            max_runs: 20
          ) do
      bad = <<channel::32, 1, sequence::64, 65_536::16>> <> :binary.copy(<<0>>, 65_536)
      assert {:error, :invalid_message} = Terminal.decode_frame(bad)
    end
  end

  test "control frames require channel zero and sequence zero" do
    payload =
      control_payload(%{
        "type" => "listing",
        "vm_id" => @id,
        "placement_id" => @id2,
        "execution_epoch" => 3
      })

    assert {:error, :invalid_message} =
             Terminal.decode_frame(<<5::32, 2, 9::64, byte_size(payload)::16, payload::binary>>)

    assert {:error, :invalid_message} =
             Terminal.decode_frame(<<0::32, 2, 9::64, byte_size(payload)::16, payload::binary>>)
  end

  test "data frames require a positive channel and sequence" do
    assert {:error, :invalid_message} = Terminal.decode_frame(<<0::32, 1, 1::64, 0::16>>)
    assert {:error, :invalid_message} = Terminal.decode_frame(<<3::32, 1, 0::64, 2::16, "hi">>)
  end

  test "create carries the full placement authority" do
    wire =
      Terminal.encode_control_frame(%{
        type: :create,
        request_id: @id,
        vm_id: @id2,
        placement_id: @id3,
        execution_epoch: 7,
        mode: :rw,
        user: "root",
        term: "xterm-256color",
        cols: 132,
        rows: 40,
        channel: 12
      })

    assert {:ok, %{channel: 0, message: create}} = Terminal.decode_frame(wire)
    assert create.placement_id == @id3
    assert create.execution_epoch == 7
    assert create.mode == :rw
    assert create.channel == 12
  end

  test "created success and failure shapes are closed" do
    ok = %{
      type: :created,
      request_id: @id,
      ok: true,
      channel: 4,
      guest_session_id: 9,
      reason: nil
    }

    assert {:ok, %{channel: 0, message: ^ok}} =
             ok |> Terminal.encode_control_frame() |> Terminal.decode_frame()

    failure = %{
      type: :created,
      request_id: @id,
      ok: false,
      channel: 4,
      guest_session_id: nil,
      reason: :limit
    }

    assert {:ok, %{channel: 0, message: ^failure}} =
             failure |> Terminal.encode_control_frame() |> Terminal.decode_frame()

    incoherent = %{
      "type" => "created",
      "request_id" => @id,
      "ok" => true,
      "channel" => 4,
      "guest_session_id" => nil,
      "reason" => "limit"
    }

    assert {:error, :invalid_message} = control_json(incoherent)
  end

  test "creation status has no unsupported-guest state" do
    status = %{
      "type" => "creation_status",
      "request_id" => @id,
      "state" => "unknown",
      "guest_session_id" => nil
    }

    assert {:ok, %{channel: 0, message: %{type: :creation_status, state: :unknown}}} =
             control_json(status)

    assert {:error, :invalid_message} = control_json(%{status | "state" => "unsupported"})
  end

  test "listings are bounded and deduplicated by guest session" do
    session = %{
      guest_session_id: 1,
      user: "root",
      cols: 80,
      rows: 24,
      viewers: 2,
      alive: true,
      created_ms: 100,
      last_ms: 200
    }

    listed = %{type: :listed, vm_id: @id, sessions: [session]}

    assert {:ok, %{channel: 0, message: ^listed}} =
             listed |> Terminal.encode_control_frame() |> Terminal.decode_frame()

    duplicate = %{
      "type" => "listed",
      "vm_id" => @id,
      "sessions" => [stringify(session), stringify(session)]
    }

    assert {:error, :invalid_message} = control_json(duplicate)

    overflow = %{
      "type" => "listed",
      "vm_id" => @id,
      "sessions" => Enum.map(1..65, fn i -> stringify(%{session | guest_session_id: i}) end)
    }

    assert {:error, :invalid_message} = control_json(overflow)
  end

  test "unknown versions and types are rejected" do
    assert {:error, :unsupported_version} =
             control_json(%{
               "type" => "listing",
               "vm_id" => @id,
               "placement_id" => @id2,
               "execution_epoch" => 1,
               "version" => 1
             })

    assert {:error, :invalid_message} =
             control_json(%{"type" => "explode", "vm_id" => @id, "version" => 2})
  end

  test "string bounds are enforced on users and terms" do
    base = %{
      "type" => "create",
      "request_id" => @id,
      "vm_id" => @id2,
      "placement_id" => @id3,
      "execution_epoch" => 1,
      "mode" => "rw",
      "user" => "root",
      "term" => "xterm-256color",
      "cols" => 80,
      "rows" => 24,
      "channel" => 1
    }

    assert {:error, :invalid_message} = control_json(%{base | "user" => ""})

    assert {:error, :invalid_message} =
             control_json(%{base | "user" => String.duplicate("x", 65)})

    assert {:error, :invalid_message} =
             control_json(%{base | "term" => String.duplicate("t", 33)})
  end

  defp hex(length), do: string(@hex_chars, length: length)

  defp uuid_gen do
    gen all(
          a <- hex(8),
          b <- hex(4),
          c <- hex(4),
          d <- hex(4),
          e <- hex(12)
        ) do
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end
  end

  defp bounded_string(max) do
    gen all(
          length <- integer(1..max),
          value <- string(:alphanumeric, length: length),
          max_tries: 20
        ) do
      value
    end
  end

  defp guest_session_gen do
    gen all(
          id <- positive_integer(),
          user <- bounded_string(64),
          cols <- integer(1..4096),
          rows <- integer(1..512),
          viewers <- integer(0..64),
          alive <- boolean(),
          created_ms <- non_negative_integer(),
          last_ms <- non_negative_integer()
        ) do
      %{
        guest_session_id: id,
        user: user,
        cols: cols,
        rows: rows,
        viewers: viewers,
        alive: alive,
        created_ms: created_ms,
        last_ms: last_ms
      }
    end
  end

  @spec recovery_query_gen(:creation_query | :creation_cancel) ::
          StreamData.t(Terminal.control_message())
  defp recovery_query_gen(type) do
    gen all(
          request_id <- uuid_gen(),
          vm <- uuid_gen(),
          placement <- uuid_gen(),
          epoch <- positive_integer()
        ) do
      %{
        type: type,
        request_id: request_id,
        vm_id: vm,
        placement_id: placement,
        execution_epoch: epoch
      }
    end
  end

  defp control_message_gen do
    control_message_generators() |> Map.values() |> one_of()
  end

  @spec consumption_gen(:input_ack | :output_ack) :: StreamData.t(Terminal.control_message())
  defp consumption_gen(type) do
    gen all(
          channel <- positive_integer(),
          frames <- non_negative_integer(),
          bytes <- non_negative_integer()
        ) do
      %{type: type, channel: channel, frames: frames, bytes: bytes}
    end
  end

  defp control_message_generators do
    %{
      users: constant(%{type: :users, vm_id: @id, placement_id: @id2, execution_epoch: 1}),
      users_listed: constant(%{type: :users_listed, vm_id: @id, users: ["root", "alice"]}),
      input_ack: consumption_gen(:input_ack),
      output_ack: consumption_gen(:output_ack),
      heartbeat:
        gen all(sequence <- positive_integer()) do
          %{type: :heartbeat, sequence: sequence}
        end,
      heartbeat_reply:
        gen all(sequence <- positive_integer()) do
          %{type: :heartbeat_reply, sequence: sequence}
        end,
      creation_query: recovery_query_gen(:creation_query),
      creation_cancel: recovery_query_gen(:creation_cancel),
      creation_status:
        gen all(
              request_id <- uuid_gen(),
              state <- member_of([:unknown, :running, :exited]),
              id <- positive_integer()
            ) do
          %{
            type: :creation_status,
            request_id: request_id,
            state: state,
            guest_session_id: if(state == :unknown, do: nil, else: id)
          }
        end,
      creation_cancelled:
        gen all(request_id <- uuid_gen(), ok <- boolean()) do
          %{type: :creation_cancelled, request_id: request_id, ok: ok}
        end,
      killed:
        gen all(
              vm <- uuid_gen(),
              placement <- uuid_gen(),
              epoch <- positive_integer(),
              id <- positive_integer(),
              ok <- boolean()
            ) do
          %{
            type: :killed,
            vm_id: vm,
            placement_id: placement,
            execution_epoch: epoch,
            guest_session_id: id,
            ok: ok
          }
        end,
      hello:
        gen all(host_id <- uuid_gen(), session_id <- uuid_gen(), epoch <- integer(1..1000)) do
          %{type: :hello, host_id: host_id, session_id: session_id, epoch: epoch}
        end,
      hello_response: constant(%{type: :hello_response, interval_ms: 1000}),
      create:
        gen all(
              request_id <- uuid_gen(),
              vm_id <- uuid_gen(),
              placement_id <- uuid_gen(),
              execution_epoch <- integer(1..1000),
              mode <- member_of([:rw, :ro]),
              user <- bounded_string(64),
              term <- bounded_string(32),
              cols <- integer(1..4096),
              rows <- integer(1..512),
              channel <- positive_integer()
            ) do
          %{
            type: :create,
            request_id: request_id,
            vm_id: vm_id,
            placement_id: placement_id,
            execution_epoch: execution_epoch,
            mode: mode,
            user: user,
            term: term,
            cols: cols,
            rows: rows,
            channel: channel
          }
        end,
      created:
        gen all(
              request_id <- uuid_gen(),
              channel <- positive_integer(),
              ok <- boolean(),
              guest_session_id <- positive_integer(),
              reason <- member_of([:dial_failed, :rejected, :limit])
            ) do
          if ok do
            %{
              type: :created,
              request_id: request_id,
              ok: true,
              channel: channel,
              guest_session_id: guest_session_id,
              reason: nil
            }
          else
            %{
              type: :created,
              request_id: request_id,
              ok: false,
              channel: channel,
              guest_session_id: nil,
              reason: reason
            }
          end
        end,
      attach:
        gen all(
              vm_id <- uuid_gen(),
              placement_id <- uuid_gen(),
              execution_epoch <- integer(1..1000),
              guest_session_id <- positive_integer(),
              mode <- member_of([:rw, :ro]),
              cursor <- non_negative_integer(),
              channel <- positive_integer()
            ) do
          %{
            type: :attach,
            cols: 80,
            rows: 24,
            vm_id: vm_id,
            placement_id: placement_id,
            execution_epoch: execution_epoch,
            guest_session_id: guest_session_id,
            mode: mode,
            cursor: cursor,
            channel: channel
          }
        end,
      attached:
        gen all(
              channel <- positive_integer(),
              ok <- boolean(),
              guest_session_id <- positive_integer(),
              from <- non_negative_integer(),
              reason <- member_of([:dial_failed, :rejected, :not_found, :fenced])
            ) do
          if ok do
            %{
              type: :attached,
              replay_bytes: 0,
              channel: channel,
              ok: true,
              guest_session_id: guest_session_id,
              from: from,
              reason: nil
            }
          else
            %{
              type: :attached,
              replay_bytes: 0,
              channel: channel,
              ok: false,
              guest_session_id: nil,
              from: nil,
              reason: reason
            }
          end
        end,
      channel_close:
        gen all(channel <- positive_integer()) do
          %{type: :channel_close, channel: channel}
        end,
      listing:
        gen all(
              vm_id <- uuid_gen(),
              placement_id <- uuid_gen(),
              execution_epoch <- integer(1..1000)
            ) do
          %{
            type: :listing,
            vm_id: vm_id,
            placement_id: placement_id,
            execution_epoch: execution_epoch
          }
        end,
      listed:
        gen all(
              vm_id <- uuid_gen(),
              ids <- uniq_list_of(positive_integer(), max_length: 4),
              sessions <- list_of(guest_session_gen(), max_length: 4)
            ) do
          sessions =
            ids
            |> Enum.zip(sessions)
            |> Enum.map(fn {id, session} -> %{session | guest_session_id: id} end)

          %{type: :listed, vm_id: vm_id, sessions: sessions}
        end,
      kill:
        gen all(
              vm_id <- uuid_gen(),
              placement_id <- uuid_gen(),
              execution_epoch <- integer(1..1000),
              guest_session_id <- positive_integer()
            ) do
          %{
            type: :kill,
            vm_id: vm_id,
            placement_id: placement_id,
            execution_epoch: execution_epoch,
            guest_session_id: guest_session_id
          }
        end,
      resize:
        gen all(
              vm_id <- uuid_gen(),
              placement_id <- uuid_gen(),
              execution_epoch <- integer(1..1000),
              guest_session_id <- positive_integer(),
              cols <- integer(1..4096),
              rows <- integer(1..512)
            ) do
          %{
            type: :resize,
            vm_id: vm_id,
            placement_id: placement_id,
            execution_epoch: execution_epoch,
            guest_session_id: guest_session_id,
            cols: cols,
            rows: rows
          }
        end,
      closed:
        gen all(
              channel <- positive_integer(),
              reason <- member_of([:session_exit, :dial_failed, :killed, :fenced])
            ) do
          %{type: :closed, channel: channel, reason: reason}
        end,
      boot_log:
        gen all(
              vm_id <- uuid_gen(),
              placement_id <- uuid_gen(),
              execution_epoch <- integer(1..1000),
              cursor <- non_negative_integer()
            ) do
          %{
            type: :boot_log,
            vm_id: vm_id,
            placement_id: placement_id,
            execution_epoch: execution_epoch,
            cursor: cursor
          }
        end,
      boot_log_data:
        gen all(
              vm_id <- uuid_gen(),
              next <- non_negative_integer(),
              bytes <- binary(max_length: 2048)
            ) do
          %{type: :boot_log_data, vm_id: vm_id, next: next, bytes: bytes}
        end
    }
  end

  defp control_json(value), do: value |> control_payload() |> Terminal.decode_frame()

  defp control_payload(value),
    do: value |> Map.put_new("version", 2) |> JSON.encode!() |> wrap_control()

  defp wrap_control(payload), do: <<0::32, 2, 0::64, byte_size(payload)::16, payload::binary>>

  defp stringify(value) do
    Map.new(value, fn {key, v} -> {Atom.to_string(key), v} end)
  end
end
