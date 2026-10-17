defmodule OverallsAntithesis.RecorderPeer do
  @moduledoc "Harness-only owner of real request-accounting workers and reviewed trace intake."
  alias Overalls.RequestAccounting.{Config, Producer}

  @type worker :: {pid(), reference()}
  @type state :: %{workers: %{pos_integer() => worker()}, next: pos_integer(), effects: binary()}
  @max_batch 128

  @spec main() :: no_return()
  def main do
    control = System.fetch_env!("FIXTURE_CONTROL")
    recorder = System.fetch_env!("FIXTURE_RECORDER")
    marker = System.fetch_env!("FIXTURE_MARKER")
    effects = System.fetch_env!("FIXTURE_EFFECTS")
    File.mkdir_p!(marker)
    File.chmod!(marker, 0o700)
    File.mkdir_p!(Path.dirname(effects))
    File.chmod!(Path.dirname(effects), 0o700)
    _ = File.rm(control)

    {:ok, _pid} =
      Producer.start_link(
        Config.new!(name: __MODULE__.Producer, socket: recorder, directory: marker)
      )

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:packet, 4},
        {:packet_size, 4096},
        {:ip, {:local, String.to_charlist(control)}}
      ])

    File.chmod!(control, 0o600)

    loop(listener, %{workers: %{}, next: 1, effects: effects})
  end

  @spec loop(:gen_tcp.socket(), state()) :: no_return()
  defp loop(listener, state) do
    {:ok, socket} = :gen_tcp.accept(listener)

    {reply, next} =
      case :gen_tcp.recv(socket, 0, 10_000) do
        {:ok, bytes} when byte_size(bytes) <= 4096 ->
          case JSON.decode(bytes) do
            {:ok, request} -> dispatch(request, state)
            _ -> {%{status: "invalid"}, state}
          end

        _ ->
          {%{status: "unavailable"}, state}
      end

    _ = :gen_tcp.send(socket, JSON.encode!(reply))
    :gen_tcp.close(socket)
    loop(listener, next)
  end

  # @cc [owner:ghuntley,label:verification] recorder-peer-real-admission
  # Every admitted slot MUST be a monitored live BEAM worker with a production
  # Producer ticket. Every attempted slot MUST append one fsynced fixture effect,
  # including measurement refusals. The response is not a durable-state oracle.
  @spec dispatch(term(), state()) :: {map(), state()}
  defp dispatch(%{"op" => "admit", "count" => count} = request, state)
       when is_integer(count) and count in 1..@max_batch and map_size(request) == 2 do
    {next, admitted} =
      Enum.reduce(1..count, {state, []}, fn _, {current, recorded} ->
        owner = spawn(fn -> worker() end)
        ticket = Producer.admit(__MODULE__.Producer, owner)
        id = current.next
        persist_effect!(current.effects, id)

        if ticket == :unrecorded do
          Process.exit(owner, :kill)
          {%{current | next: id + 1}, recorded}
        else
          {%{current | next: id + 1, workers: Map.put(current.workers, id, {owner, ticket})},
           [id | recorded]}
        end
      end)

    {%{
       status: "ok",
       attempted: count,
       admitted: Enum.reverse(admitted),
       last_effect: next.next - 1
     }, next}
  end

  defp dispatch(%{"op" => "finish", "id" => id, "outcome" => outcome} = request, state)
       when is_integer(id) and id > 0 and outcome in ["success", "failure", "exclude"] and
              map_size(request) == 3 do
    case Map.pop(state.workers, id) do
      {nil, _} ->
        {%{status: "unknown"}, state}

      {{owner, ticket}, workers} ->
        selected = String.to_existing_atom(outcome)
        :ok = Producer.complete(__MODULE__.Producer, ticket, selected, 100)
        send(owner, :stop)
        {%{status: "ok"}, %{state | workers: workers}}
    end
  end

  defp dispatch(%{"op" => "finish_many", "ids" => ids} = request, state)
       when is_list(ids) and length(ids) in 1..@max_batch and map_size(request) == 2 do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)) and length(Enum.uniq(ids)) == length(ids) do
      {next, finished} =
        Enum.reduce(ids, {state, 0}, fn id, {current, count} ->
          {reply, updated} =
            dispatch(%{"op" => "finish", "id" => id, "outcome" => "success"}, current)

          {updated, count + if(reply.status == "ok", do: 1, else: 0)}
        end)

      {%{status: "ok", finished: finished}, next}
    else
      {%{status: "invalid"}, state}
    end
  end

  defp dispatch(%{"op" => "kill_worker", "id" => id} = request, state)
       when is_integer(id) and id > 0 and map_size(request) == 2 do
    case Map.pop(state.workers, id) do
      {nil, _} ->
        {%{status: "unknown"}, state}

      {{owner, _ticket}, workers} ->
        monitor = Process.monitor(owner)
        Process.exit(owner, :kill)

        died =
          receive do
            {:DOWN, ^monitor, :process, ^owner, :killed} -> true
          after
            5_000 -> false
          end

        {%{status: if(died, do: "ok", else: "unavailable")}, %{state | workers: workers}}
    end
  end

  defp dispatch(%{"op" => "trace", "sequence" => sequence, "size" => size} = request, state)
       when is_integer(sequence) and sequence in 1..1_000_000 and size in ["small", "large"] and
              map_size(request) == 3 do
    dispatch_trace(sequence, size, false, state)
  end

  defp dispatch(
         %{"op" => "trace", "sequence" => sequence, "size" => size, "lose_ack" => true} = request,
         state
       )
       when is_integer(sequence) and sequence in 1..1_000_000 and size in ["small", "large"] and
              map_size(request) == 4 do
    dispatch_trace(sequence, size, true, state)
  end

  defp dispatch(%{"op" => "hello"} = request, state) when map_size(request) == 1,
    do: {%{status: "ok", live: map_size(state.workers), next_effect: state.next}, state}

  defp dispatch(%{"op" => "recorder_uncertain_admit"} = request, state)
       when map_size(request) == 1 do
    path = System.fetch_env!("FIXTURE_RECORDER")
    options = [:binary, {:active, false}, {:packet, 4}, {:packet_size, 512}]

    result =
      case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, options, 1_000) do
        {:ok, socket} ->
          sent = :gen_tcp.send(socket, JSON.encode!(%{version: 1, command: %{op: :admit}}))
          :gen_tcp.close(socket)
          if sent == :ok, do: "uncertain", else: "unavailable"

        _ ->
          "unavailable"
      end

    {%{status: result}, state}
  end

  defp dispatch(_, state), do: {%{status: "invalid"}, state}

  @spec dispatch_trace(pos_integer(), binary(), boolean(), state()) :: {map(), state()}
  defp dispatch_trace(sequence, size, lose_ack, state) do
    source = if size == "small", do: "FIXTURE_TRACE_SMALL", else: "FIXTURE_TRACE_LARGE"

    old =
      if size == "small",
        do:
          <<0x1D, 0x89, 0xFE, 0xAF, 0xBA, 0x35, 0xEC, 0xD3, 0x3A, 0x11, 0x57, 0x21, 0xF8, 0x07,
            0xB9, 0xB3>>,
        else:
          <<0x3B, 0x63, 0xEA, 0x6F, 0xB7, 0xD0, 0x72, 0x03, 0xB1, 0x37, 0xC3, 0xB6, 0x64, 0xE6,
            0xC6, 0xA0>>

    template =
      System.fetch_env!(source) |> File.read!() |> String.trim() |> Base.decode16!(case: :mixed)

    body = :binary.replace(template, old, <<sequence::128>>, [:global])
    result = trace_request(System.fetch_env!("FIXTURE_TRACE_SOCKET"), body, lose_ack)
    {%{status: result}, state}
  end

  @spec worker() :: :ok
  defp worker do
    receive do
      :stop -> :ok
    end
  end

  @spec persist_effect!(binary(), pos_integer()) :: :ok
  defp persist_effect!(path, id) do
    {:ok, file} = File.open(path, [:append, :binary])
    File.chmod!(path, 0o600)
    :ok = IO.binwrite(file, Integer.to_string(id) <> "\n")
    :ok = :file.sync(file)
    :ok = File.close(file)
  end

  @spec trace_request(binary(), binary(), boolean()) :: binary()
  defp trace_request(path, body, lose_ack) do
    options = [:binary, {:active, false}]

    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, options, 1_000) do
      {:ok, socket} ->
        request = [
          "POST /v1/traces HTTP/1.1\r\nContent-Type: application/x-protobuf\r\n",
          "Content-Length: ",
          Integer.to_string(byte_size(body)),
          "\r\n\r\n",
          body
        ]

        result =
          case :gen_tcp.send(socket, request) do
            :ok when lose_ack ->
              # The complete real request reached the Unix stream. Closing
              # before recv deliberately discards the spool's intake reply.
              "uncertain"

            :ok ->
              case :gen_tcp.recv(socket, 0, 1_000) do
                {:ok, <<"HTTP/1.1 ", code::binary-size(3), _::binary>>}
                when code in ["200", "400", "403", "429", "503"] ->
                  code

                _ ->
                  "unavailable"
              end

            _ ->
              "unavailable"
          end

        :gen_tcp.close(socket)
        result

      _ ->
        "unavailable"
    end
  end
end

OverallsAntithesis.RecorderPeer.main()
