defmodule OverallsProtocol.TerminalAttachTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.{SSHCommand, TerminalAttach}

  # Shared with Mila's Dart decoder: the header line and exit-status table.
  @fixture Path.expand("fixtures/terminal_attach.json", __DIR__)
  @external_resource @fixture

  @spec fixture() :: map()
  defp fixture, do: @fixture |> File.read!() |> JSON.decode!()

  test "the shared fixture matches the encoder, decoder and closed tables" do
    data = fixture()
    assert data["version"] == 1
    assert data["gateway_stream"]["path"] == TerminalAttach.path()

    assert data["gateway_stream"]["headers"] ==
             ["authorization", TerminalAttach.session_header(), TerminalAttach.ticket_header()]

    for %{"line" => line, "header" => expected} <- data["headers"] do
      assert {:ok, header} = TerminalAttach.decode(line)
      assert TerminalAttach.encode(header) == line

      case header do
        {:attached, attached} ->
          assert expected == %{
                   "kind" => "attached",
                   "from" => attached.from,
                   "replay_bytes" => attached.replay_bytes,
                   "mode" => Atom.to_string(attached.mode)
                 }

        {:refused, error} ->
          assert expected == %{"kind" => "refused", "error" => Atom.to_string(error)}
      end
    end

    for line <- data["invalid_headers"],
        do: assert({:error, :invalid_header} = TerminalAttach.decode(line))

    statuses =
      for %{"status" => status, "outcome" => outcome} <- data["exit_codes"] do
        outcome = String.to_existing_atom(outcome)
        assert TerminalAttach.exit_status(outcome) == status
        outcome
      end

    assert statuses == TerminalAttach.outcomes()

    for %{"code" => code, "outcome" => outcome} <- data["close_codes"],
        do: assert(Atom.to_string(TerminalAttach.close_outcome(code)) == outcome)

    errors =
      for %{"error" => name, "outcome" => outcome} <- data["errors"] do
        error = TerminalAttach.error(name)
        assert Atom.to_string(error) == name
        assert Atom.to_string(TerminalAttach.error_outcome(error)) == outcome
        name
      end

    assert Enum.sort(errors) == TerminalAttach.errors()
  end

  test "terminal attach is a non-mutating read with a bounded cursor and read-only flag" do
    session = "11111111-1111-4111-8111-111111111111"

    assert {:ok, command} =
             SSHCommand.parse("terminal attach dev #{session} --cursor 42 --read-only")

    assert command.command == "terminal attach"
    assert command.arguments == ["dev", session]
    assert command.options == %{"cursor" => "42", "read-only" => true}
    assert SSHCommand.attach?(command)
    refute SSHCommand.mutation?("terminal attach")
    refute SSHCommand.physical?("terminal attach")

    for text <- [
          "terminal attach dev",
          "terminal attach dev not-a-uuid",
          "terminal attach dev #{session} --cursor -1",
          "terminal attach dev #{session} --cursor 01",
          "terminal attach dev #{session} --cursor 9223372036854775808",
          "terminal attach dev #{session} --request-id x",
          "terminal attach dev #{session} --no-wait"
        ],
        do: assert({:error, :invalid_command} = SSHCommand.parse(text), text)

    assert {:ok, _} = SSHCommand.parse("terminal attach dev #{session} --cursor 0")
    refute SSHCommand.attach?(elem(SSHCommand.parse("whoami"), 1))
  end

  test "the stream path carries only cursor and geometry" do
    assert TerminalAttach.stream_path(7, 80, 24) ==
             "/api/terminal-gateway/v1/stream?cursor=7&cols=80&rows=24"
  end

  # @cc [owner:ghuntley,label:verification;protocol] terminal-attach-exit-table-property
  # Every close code, HTTP status and refusal maps to one outcome whose exit
  # status is in the closed table; only a normal close is a success.
  property "every close code, status and refusal maps into the closed exit table" do
    code = draw("code", one_of([integer(0..65_535), member_of([1000, 4001, 4003, nil])]))
    status = draw("status", integer(100..599))
    name = draw("name", one_of([member_of(TerminalAttach.errors()), string(max_length: 24)]))

    close = TerminalAttach.close_outcome(code)
    upgrade = TerminalAttach.status_outcome(status)
    refusal = TerminalAttach.error_outcome(TerminalAttach.error(name))

    for outcome <- [close, upgrade, refusal] do
      assert outcome in TerminalAttach.outcomes()
      assert TerminalAttach.exit_status(outcome) in [0, 1, 2, 3, 5]
    end

    assert TerminalAttach.exit_status(close) == 0 == (code == 1000)
    assert TerminalAttach.close_outcome(TerminalAttach.close_code(close)) == close
    assert upgrade in [:authority, :refused, :transport]
    assert refusal in [:invalid, :authority, :refused, :transport]
  end

  property "header lines round-trip and arbitrary input never raises" do
    header =
      draw(
        "header",
        one_of([
          map(
            tuple([integer(0..9_223_372_036_854_775_807), integer(0..1_000_000), boolean()]),
            fn {from, replay, writable} ->
              {:attached,
               %{from: from, replay_bytes: replay, mode: if(writable, do: :rw, else: :ro)}}
            end
          ),
          map(member_of(TerminalAttach.errors()), &{:refused, TerminalAttach.error(&1)})
        ])
      )

    line = TerminalAttach.encode(header)
    assert String.ends_with?(line, "\n")
    assert {:ok, ^header} = TerminalAttach.decode(line)

    noise = draw("noise", binary(max_length: 600))

    case TerminalAttach.decode(noise) do
      {:ok, decoded} ->
        assert TerminalAttach.decode(TerminalAttach.encode(decoded)) == {:ok, decoded}

      {:error, :invalid_header} ->
        :ok
    end
  end
end
