defmodule Porsche.ClientCommandsTest do
  @moduledoc "Porsche handling of Mila's thread, terminal, web and watch commands (ADR-0222)."
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.SSHCommand
  alias Porsche.{Runner, Watchers}
  alias Porsche.SSH.{Output, Watch}

  @thread "44444444-4444-4444-8444-444444444444"
  @machine "33333333-3333-4333-8333-333333333333"
  @session "11111111-1111-4111-8111-111111111111"

  @spec client() :: Porsche.Client.t()
  defp client do
    {:ok, client} =
      Porsche.Client.new(
        "https://marshall.test",
        "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
      )

    client
  end

  @spec recorder([{:ok, map()} | {:error, atom()}]) :: {keyword(), (-> [map()])}
  defp recorder(replies) do
    key = make_ref()
    Process.put(key, %{replies: replies, calls: []})

    request = fn _client, "commands", message, _options ->
      %{replies: [reply | rest], calls: calls} = Process.get(key)
      Process.put(key, %{replies: rest, calls: calls ++ [message]})
      reply
    end

    {[request: request, sleep: fn _ -> :ok end], fn -> Process.get(key).calls end}
  end

  test "payload commands without their stdin payload never contact Marshall" do
    for line <- [
          "thread prompt #{@thread} -",
          "thread answer #{@thread} #{@session} -",
          "thread plan revise #{@thread} #{@session} -"
        ] do
      {options, calls} = recorder([])
      result = Runner.run(client(), "s", line, options)
      assert result.exit_status == 2
      assert result.response["error"] == "stdin_payload_required"
      assert result.response["hint"] =~ "standard input"
      assert calls.() == []
    end

    {options, calls} = recorder([])

    assert %{exit_status: 2, response: %{"error" => "invalid_command"}} =
             Runner.run(client(), "s", "watch --thread #{@thread}", options)

    assert calls.() == []
  end

  test "a supplied payload dispatches once as a synchronous, identified mutation" do
    {:ok, command} = SSHCommand.parse("thread prompt #{@thread} -")
    {:ok, command} = SSHCommand.put_stdin_payload(command, "Run the tests.")

    reply = fn [message] ->
      {:ok,
       %{
         "version" => 1,
         "request_id" => message["command"]["options"]["request-id"],
         "operation_id" => nil,
         "status" => "succeeded",
         "result" => %{"thread_id" => @thread, "status" => "queued"}
       }}
    end

    key = make_ref()

    options = [
      request: fn _client, "commands", message, _ ->
        Process.put(key, [message | Process.get(key, [])])
        reply.([message])
      end
    ]

    result = Runner.run_command(client(), "s", command, options)
    assert result.exit_status == 0
    assert [sent] = Process.get(key)
    assert sent["command"]["options"]["stdin"] == "Run the tests."
    assert "porsche-" <> _ = sent["command"]["options"]["request-id"]
  end

  test "thread, terminal and web refusals keep closed reasons, exit 2 and translated text" do
    for reason <- [
          :thread_busy,
          :stale_proposal,
          :revision_conflict,
          :reserved_editor_port,
          :unknown_session,
          :terminal_unavailable
        ] do
      {options, calls} = recorder([{:error, reason}])
      result = Runner.run(client(), "s", "web set box-1 --public", options)
      assert result.exit_status == 2
      assert result.response["error"] == Atom.to_string(reason)
      assert length(calls.()) == 1
      text = Output.render(result.response, false)
      refute text =~ "could not be completed"
    end

    Gettext.put_locale(Porsche.Gettext, "fr")
    response = %{"version" => 1, "status" => "error", "error" => "revision_conflict"}
    refute Output.render(response, false) =~ "The web settings changed"
  after
    Gettext.put_locale(Porsche.Gettext, "en")
  end

  test "subscription answers must name exactly the requested identifiers" do
    {:ok, command} = SSHCommand.parse("watch --machine box-1 --thread #{@thread} --session")
    watch = Watch.new(command)
    assert watch.machines == ["box-1"] and watch.threads == [@thread] and watch.session

    good = %{"session_id" => @session, "machines" => [@machine], "threads" => [@thread]}
    assert {:ok, subscription} = Watch.subscription(watch, good)

    assert Watch.keys(watch, subscription) == [
             :resync,
             {"vm", @machine},
             {"terminal_session", @machine},
             {"thread", @thread},
             {"ssh_session", @session}
           ]

    for bad <- [
          Map.put(good, "extra", 1),
          %{good | "machines" => []},
          %{good | "machines" => ["box-1"]},
          %{good | "session_id" => "x"},
          %{good | "threads" => [@thread, @thread]}
        ] do
      assert {:error, :invalid_response} = Watch.subscription(watch, bad)
    end
  end

  # @cc [owner:ghuntley,label:verification;protocol] porsche-watch-coalescing
  # Any sequence of hints MUST drain to one identifier-only notice per distinct
  # hint, in a stable order, and leave no queued hint or flush timer behind.
  property "queued hints drain to one identifier notice per distinct hint",
    database: :disabled,
    print_blob: false,
    test_cases: 200,
    seed: 2_026_101_825 do
    {:ok, command} = SSHCommand.parse("watch --thread #{@thread}")
    ids = [@thread, @machine, @session]

    hints =
      draw(
        "hints",
        list_of(
          tuple([member_of(["vm", "thread", "terminal_session", "ssh_session"]), member_of(ids)]),
          max_length: 20
        )
      )

    watch =
      Enum.reduce(hints, Watch.new(command), fn {kind, id}, watch ->
        {watch, _schedule?} = Watch.queue(watch, kind, id)
        watch
      end)

    {notices, drained} = Watch.drain(watch)
    assert length(notices) == hints |> Enum.uniq() |> length()
    assert drained.pending == MapSet.new() and drained.flush == nil

    for notice <- notices do
      assert notice["version"] == 1
      assert notice["event"] in ["machine", "thread", "terminal_session", "session"]
      assert Map.keys(notice) -- ["version", "event", "id", "machine_id"] == []
    end
  end

  test "hints reach only exact registrations and resync reaches every watcher" do
    parent = self()

    watcher = fn keys ->
      spawn_link(fn ->
        Watchers.watch(keys)
        send(parent, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)
    end

    thread_watcher = watcher.([:resync, {"thread", @thread}])
    machine_watcher = watcher.([:resync, {"vm", @machine}])
    assert_receive {:registered, ^thread_watcher}
    assert_receive {:registered, ^machine_watcher}

    :erlang.trace(thread_watcher, true, [:receive])
    :erlang.trace(machine_watcher, true, [:receive])

    Watchers.hint("thread", @thread)
    assert_receive {:trace, ^thread_watcher, :receive, {:watch_hint, "thread", @thread}}
    refute_receive {:trace, ^machine_watcher, :receive, {:watch_hint, _, _}}, 50

    Watchers.hint("unknown", @thread)
    Watchers.hint("thread", 7)
    refute_receive {:trace, _, :receive, {:watch_hint, _, _}}, 50

    Watchers.resync()
    assert_receive {:trace, ^thread_watcher, :receive, :watch_resync}
    assert_receive {:trace, ^machine_watcher, :receive, :watch_resync}

    for pid <- [thread_watcher, machine_watcher], do: send(pid, :stop)
  end
end
