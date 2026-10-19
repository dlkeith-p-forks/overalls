defmodule OverallsProtocol.SSHClientCommandsTest do
  @moduledoc "Thread, terminal, web and watch commands added for Mila (ADR-0222)."
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.{SSHCommand, SSHManagement}

  @thread "0d9cc041-9db2-4e4c-b28b-1e41d7f472c1"
  @question "6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b"

  @spec uuid() :: Hegel.Gen.t()
  defp uuid do
    map(binary(min_length: 16, max_length: 16), fn bytes ->
      <<a::32, b::16, c::16, d::16, e::48>> = bytes

      hex = fn value, width ->
        value |> Integer.to_string(16) |> String.pad_leading(width, "0")
      end

      String.downcase(
        Enum.join([hex.(a, 8), hex.(b, 4), hex.(c, 4), hex.(d, 4), hex.(e, 12)], "-")
      )
    end)
  end

  @spec machine() :: Hegel.Gen.t()
  defp machine,
    do: one_of([map(integer(1..999_999), &"box-#{&1}"), uuid()])

  @spec client_command(term()) :: SSHCommand.t()
  defp client_command(test_case) do
    _ = test_case
    thread = draw("thread", uuid())
    other = draw("other", uuid())
    box = draw("machine", machine())
    sequence = Integer.to_string(draw("sequence", integer(0..2_147_483_647)))

    request =
      "porsche-" <>
        Base.encode16(draw("request", binary(min_length: 16, max_length: 16)), case: :lower)

    choice =
      draw(
        "choice",
        member_of([
          {"thread ls", [], %{"machine" => box, "after" => thread}},
          {"thread show", [thread], %{}},
          {"thread turns", [thread], %{"after" => sequence}},
          {"thread prompt", [thread, "-"], %{"request-id" => request}},
          {"thread answer", [thread, other, "-"], %{}},
          {"thread plan approve", [thread, other], %{"request-id" => request}},
          {"thread plan revise", [thread, other, "-"], %{}},
          {"thread mode", [thread, "plan"], %{}},
          {"thread mode", [thread, "work"], %{"request-id" => request}},
          {"thread read", [thread, sequence], %{}},
          {"terminal ls", [box], %{}},
          {"terminal new", [box], %{"request-id" => request}},
          {"terminal kill", [box, other], %{}},
          {"web show", [box], %{}},
          {"web set", [box], %{"port" => "8080", "public" => true, "revision" => "7"}},
          {"web set", [box], %{"private" => true}},
          {"watch", [], %{"machine" => [box, other], "thread" => thread, "session" => true}},
          {"watch", [], %{"session" => true}}
        ])
      )

    {name, arguments, options} = choice
    json = draw("json", boolean())
    options = if json, do: Map.put(options, "json", true), else: options
    %{version: 1, command: name, arguments: arguments, options: options}
  end

  property "client commands format to canonical lines that parse back unchanged",
    database: :disabled,
    print_blob: false,
    test_cases: 200,
    seed: 2_026_101_822 do
    command = client_command(nil)

    assert {:ok, line} = SSHCommand.format(command)
    assert {:ok, ^command} = SSHCommand.parse(line)
    refute String.contains?(line, ["\n", "\r", <<0>>])
    assert byte_size(line) <= 8192

    assert SSHCommand.mutation?(command.command) ==
             command.command in [
               "thread prompt",
               "thread answer",
               "thread plan approve",
               "thread plan revise",
               "thread mode",
               "thread read",
               "terminal new",
               "terminal kill",
               "web set"
             ]

    refute SSHCommand.physical?(command.command)
  end

  property "a corrupted argument or unknown option is refused before dispatch",
    database: :disabled,
    print_blob: false,
    test_cases: 200,
    seed: 2_026_101_823 do
    command = client_command(nil)
    garbage = draw("garbage", member_of(["", "x", "-1", "01", "plan-ish", "NOT-A-UUID", "--x"]))

    corrupted =
      case command.arguments do
        [] -> %{command | options: Map.put(command.options, "bogus", garbage)}
        [_ | rest] -> %{command | arguments: [garbage | rest]}
      end

    wire = %{
      "version" => 1,
      "command" => corrupted.command,
      "arguments" => corrupted.arguments,
      "options" => corrupted.options
    }

    # Machine names accept a few garbage spellings ("x"); every UUID slot refuses.
    case {corrupted.command, garbage} do
      {name, "x"}
      when name in ["terminal ls", "terminal new", "terminal kill", "web show", "web set"] ->
        :ok

      {name, "plan-ish"}
      when name in ["terminal ls", "terminal new", "terminal kill", "web show", "web set"] ->
        :ok

      _ ->
        assert {:error, :invalid_command} = SSHCommand.validate(wire)
    end
  end

  property "stdin payloads are bounded valid text and never accepted on the command line",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 2_026_101_824 do
    text =
      draw(
        "text",
        OverallsProtocol.TestGenerators.string(:printable, min_length: 1, max_length: 512)
      )

    {:ok, prompt} = SSHCommand.parse("thread prompt #{@thread} - --json")
    assert SSHCommand.stdin_payload?(prompt) == {:prompt, 65_536}
    refute SSHCommand.stdin_secret?(prompt)

    if String.trim(text) == "" do
      assert {:error, :invalid_command} = SSHCommand.put_stdin_payload(prompt, text)
    else
      assert {:ok, supplied} = SSHCommand.put_stdin_payload(prompt, text)
      assert supplied.options["stdin"] == text
      assert SSHCommand.stdin_payload?(supplied) == false
      assert {:error, :invalid_command} = SSHCommand.format(supplied)
      # Re-supplying a payload is refused; a validated structure carries one.
      assert {:error, :invalid_command} = SSHCommand.put_stdin_payload(supplied, text)
    end

    assert {:error, :invalid_command} = SSHCommand.parse("thread prompt #{@thread} - --stdin=x")
  end

  test "payload limits, NUL and invalid UTF-8 are refused" do
    {:ok, prompt} = SSHCommand.parse("thread prompt #{@thread} -")
    {:ok, revise} = SSHCommand.parse("thread plan revise #{@thread} #{@question} -")
    {:ok, answer} = SSHCommand.parse("thread answer #{@thread} #{@question} -")

    assert {:ok, _} = SSHCommand.put_stdin_payload(prompt, String.duplicate("a", 65_536))
    assert {:error, _} = SSHCommand.put_stdin_payload(prompt, String.duplicate("a", 65_537))
    assert {:error, _} = SSHCommand.put_stdin_payload(prompt, "a" <> <<0>>)
    assert {:error, _} = SSHCommand.put_stdin_payload(prompt, <<0xFF, 0xFE>>)
    assert {:error, _} = SSHCommand.put_stdin_payload(prompt, "")
    assert {:ok, _} = SSHCommand.put_stdin_payload(revise, "Split step two.\n")
    assert SSHCommand.stdin_payload?(answer) == {:answers, 65_536}

    assert {:ok, _} =
             SSHCommand.put_stdin_payload(answer, ~s({"approach":{"selected":"First","text":""}}))

    for invalid <- ["[]", "\"text\"", "{", "null"] do
      assert {:error, _} = SSHCommand.put_stdin_payload(answer, invalid), invalid
    end
  end

  test "the integration secret keeps its own stdin kind and limit" do
    {:ok, command} =
      SSHCommand.parse("integration add api --target https://api.example.test --bearer -")

    assert SSHCommand.stdin_payload?(command) == {:secret, 4098}
    assert SSHCommand.stdin_secret?(command)
    assert {:ok, replaced} = SSHCommand.put_stdin_payload(command, "secret-token")
    assert replaced.options["bearer"] == "secret-token"
    refute SSHCommand.stdin_payload?(replaced)
  end

  test "watch filters repeat within bounds and name at least one subscription" do
    machines = Enum.map_join(1..16, " ", &"--machine=box-#{&1}")
    assert {:ok, watch} = SSHCommand.parse("watch #{machines} --session")
    assert length(watch.options["machine"]) == 16
    assert {:error, _} = SSHCommand.parse("watch #{machines} --machine=box-17")
    assert {:error, _} = SSHCommand.parse("watch")
    assert {:error, _} = SSHCommand.parse("thread ls --machine=a --machine=b")

    assert {:ok, %{options: %{"thread" => [@thread, @question]}}} =
             SSHCommand.parse("watch --thread #{@thread} --thread #{@question}")
  end

  test "help covers three-word commands and the catalog hides the stdin option" do
    assert {:ok, %{command: "help"}} = SSHCommand.parse("help thread plan approve")
    entry = Enum.find(SSHCommand.catalog(), &(&1.name == "thread prompt"))
    assert entry.mutation
    refute "stdin" in entry.options
  end

  test "watch subscriptions are closed, bounded management envelopes" do
    token = "porsche_session_" <> String.duplicate("A", 43)

    assert {:ok, %{machines: ["box-1"], threads: [@thread]}} =
             SSHManagement.request("watch_subscribe", %{
               "version" => 1,
               "session_token" => token,
               "machines" => ["box-1"],
               "threads" => [@thread]
             })

    for invalid <- [
          %{"version" => 1, "session_token" => token, "machines" => ["Box"], "threads" => []},
          %{"version" => 1, "session_token" => token, "machines" => [], "threads" => ["x"]},
          %{
            "version" => 1,
            "session_token" => token,
            "machines" => Enum.map(1..17, &"box-#{&1}"),
            "threads" => []
          },
          %{"version" => 1, "session_token" => token, "machines" => [], "threads" => [], "x" => 1}
        ] do
      assert {:error, :invalid_request} = SSHManagement.request("watch_subscribe", invalid)
    end
  end
end
