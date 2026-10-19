defmodule Marshall.SSH.ClientCommandsTest do
  @moduledoc "Thread, web and watch dispatch for Porsche client commands (ADR-0222)."
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias Marshall.{SSH, Threads}
  alias Marshall.Agents.{Planning, PlanProposal, PlanningQuestion, Turn}
  alias Marshall.Agents.Thread, as: AgentThread
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.SSH.{Request, Token}
  alias Marshall.Threads.{ProvisionWorker, ReadMarker, Thread}
  alias OverallsProtocol.SSHCommand

  @fixture Path.expand("../../../../protocol/test/fixtures/porsche_client_results.json", __DIR__)

  @type context :: %{
          required(:actor) => Marshall.Accounts.User.t(),
          required(:key) => map(),
          required(:gateway_token) => String.t(),
          required(:session_token) => String.t(),
          optional(atom()) => term()
        }

  setup do
    fixture = host_fixture()
    actor = user()
    public_key = public_key(<<7::256>>)
    {:ok, key} = SSH.add_key(%{public_key: public_key}, actor: actor)
    {gateway_token, _} = Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "client-fixture", token: gateway_token},
        actor: SystemActor.compute()
      )

    {:ok, session} =
      SSH.open_session(%{gateway_token: gateway_token, public_key: public_key},
        actor: SystemActor.compute()
      )

    Map.merge(fixture, %{
      actor: actor,
      key: key,
      gateway_token: gateway_token,
      session_token: session.session_token
    })
  end

  # @cc [owner:ghuntley,label:verification;security] ssh-thread-commands-dispatch
  # Thread commands MUST read and mutate only through the Threads domain with
  # the SSH actor: listing reports unread counts, prompts arrive only as stdin
  # payloads whose receipts keep a digest and the SSH key, and read markers
  # never move backwards.
  test "thread commands list, show, prompt and mark read through the domain", c do
    thread = c |> thread() |> idle()
    append(thread, :assistant, %{"text" => "first answer"})
    append(thread, :assistant, %{"text" => "second answer"})

    assert {:ok, %{"items" => [listed], "next_cursor" => nil}} = command(c, "thread ls")
    assert listed["id"] == thread.id
    assert listed["mine"]
    assert listed["unread"] >= 2
    assert listed["route"] == Marshall.AppRoutes.link({:thread, thread.id})
    refute Map.has_key?(listed, "objective")

    machine = Ledger.read!(VirtualMachine, id: thread.machine_id) |> hd()
    assert {:ok, %{"items" => [_]}} = command(c, "thread ls --machine #{machine.name}")

    assert {:ok, shown} = command(c, "thread show #{thread.id}")
    assert shown["busy"] == false
    assert shown["pending_question"] == nil

    assert {:ok, %{"items" => events, "next_after" => nil}} =
             command(c, "thread turns #{thread.id}")

    assert Enum.map(events, & &1["sequence"]) == Enum.sort(Enum.map(events, & &1["sequence"]))
    last = List.last(events)["sequence"]
    assert {:ok, %{"items" => []}} = command(c, "thread turns #{thread.id} --after #{last}")

    assert {:ok, %{status: "succeeded", result: read}} =
             receipt(c, "thread read #{thread.id} #{last} --request-id read-1")

    assert read["unread"] == 0 and read["read_sequence"] == last
    assert {:ok, %{result: lower}} = receipt(c, "thread read #{thread.id} 1 --request-id read-2")
    assert lower["read_sequence"] == last

    prompt = "Summarise the deployment notes."

    assert {:ok, %{status: "succeeded", result: submitted}} =
             receipt(c, "thread prompt #{thread.id} - --request-id prompt-1", prompt)

    assert submitted["thread_id"] == thread.id
    assert is_binary(submitted["turn_id"])
    [turn] = Ledger.read!(Turn, id: submitted["turn_id"])
    assert turn.prompt == prompt

    assert {:ok, %{result: replay}} =
             receipt(c, "thread prompt #{thread.id} - --request-id prompt-1", prompt)

    assert replay["turn_id"] == submitted["turn_id"]

    assert {:error, :idempotency_conflict} =
             receipt(c, "thread prompt #{thread.id} - --request-id prompt-1", "other")

    [request] = Ledger.read!(Request, user_id: c.actor.id, request_id: "prompt-1")
    assert request.ssh_key_id == c.key.id
    refute JSON.encode!(request.command) =~ prompt
    assert request.command["options"]["stdin"] =~ "digest:"

    assert {:error, :thread_busy} =
             receipt(c, "thread mode #{thread.id} plan --request-id mode-busy")
  end

  test "a payload command without its stdin payload is refused before dispatch", c do
    thread = c |> thread() |> idle()
    assert {:error, :invalid_command} = command(c, "thread prompt #{thread.id} -")
    assert {:error, :invalid_command} = command(c, "watch --session")
    assert Ledger.read!(Request, user_id: c.actor.id) == []
  end

  test "thread answer and plan commands keep the domain's question and proposal fences", c do
    thread = c |> thread() |> idle()
    question = question(thread, c.actor)

    assert {:ok, %{"pending_question" => %{"id" => question_id}}} =
             command(c, "thread show #{thread.id}")

    assert question_id == question.id

    assert {:error, :invalid_answers} =
             receipt(
               c,
               "thread answer #{thread.id} #{question.id} - --request-id answer-bad",
               ~s({"approach":{"selected":"Third","text":""}})
             )

    assert {:ok, %{result: %{"status" => "answered"}}} =
             receipt(
               c,
               "thread answer #{thread.id} #{question.id} - --request-id answer-1",
               ~s({"approach":{"selected":"First","text":""}})
             )

    [answered] = Ledger.read!(PlanningQuestion, id: question.id)
    assert answered.status == :answered

    [agent] = Ledger.read!(AgentThread, id: thread.agent_thread_id)
    Enum.each(Ledger.read!(Turn, thread_id: agent.id), &complete/1)
    Ledger.update!(agent, :advance, %{active_turn_id: nil})
    plan = proposal(thread)

    assert {:error, :stale_proposal} =
             receipt(
               c,
               "thread plan revise #{thread.id} #{Ash.UUID.generate()} - --request-id revise-stale",
               "Split step two."
             )

    assert {:ok, %{result: approved}} =
             receipt(c, "thread plan approve #{thread.id} #{plan.id} --request-id approve-1")

    assert approved["collaboration_mode"] == "work"
    [implementation] = Ledger.read!(Turn, id: approved["turn_id"])
    assert implementation.collaboration_mode == :work
  end

  # @cc [owner:ghuntley,label:verification;concurrency] ssh-web-set-revision-fence
  # `web set` MUST change only named settings and refuse a stale expected
  # revision with revision_conflict, leaving the endpoint unchanged.
  test "web show and web set use the endpoint's optimistic policy revision", c do
    vm = machine(c, "web-box")
    assert {:ok, shown} = command(c, "web show web-box")
    assert shown["machine_id"] == vm.id
    assert shown["visibility"] == "private"
    revision = shown["policy_revision"]

    assert {:ok, %{result: changed}} =
             receipt(c, "web set web-box --port 8080 --public --request-id web-1")

    assert changed["port"] == 8080
    assert changed["visibility"] == "public"
    assert changed["policy_revision"] == revision + 1

    assert {:error, :revision_conflict} =
             receipt(c, "web set web-box --private --revision #{revision} --request-id web-2")

    assert {:error, :reserved_editor_port} =
             receipt(c, "web set web-box --port 4444 --request-id web-3")

    assert {:ok, %{"visibility" => "public", "port" => 8080}} = command(c, "web show web-box")
    [request] = Ledger.read!(Request, user_id: c.actor.id, request_id: "web-1")
    assert request.vm_id == vm.id
    assert request.ssh_key_id == c.key.id
  end

  # @cc [owner:ghuntley,label:verification;recovery] ssh-terminal-detached-refusal
  # Terminal commands on a machine without a reachable terminal stream MUST
  # return a closed refusal and pin no receipt; an unknown session id is
  # unknown_session. Physical session opening is covered by the transport test.
  test "terminal commands refuse closed reasons without pinning receipts", c do
    machine(c, "term-box")
    before = Ledger.read!(Request, user_id: c.actor.id)

    assert {:error, listed} = command(c, "terminal ls term-box")
    assert {:error, opened} = receipt(c, "terminal new term-box --request-id term-1")

    assert {:error, :unknown_session} =
             receipt(c, "terminal kill term-box #{Ash.UUID.generate()} --request-id term-2")

    for reason <- [listed, opened] do
      assert reason in [
               :terminal_unavailable,
               :terminal_open_pending,
               :machine_unavailable,
               :opening_expired
             ]
    end

    assert Ledger.read!(Request, user_id: c.actor.id) == before
  end

  # @cc [owner:ghuntley,label:verification;security] ssh-watch-subscription-refusal
  # A watch subscription MUST name only readable machines and threads and
  # refuse a stranger's thread as a whole.
  test "watch subscriptions authorize every named machine and thread", c do
    thread = c |> thread() |> idle()
    vm = machine(c, "watch-box")

    assert {:ok, %{machines: [machine_id], threads: [thread_id], session_id: session_id}} =
             SSH.watch_subscribe(
               %{
                 gateway_token: c.gateway_token,
                 session_token: c.session_token,
                 machines: ["watch-box"],
                 threads: [thread.id]
               },
               actor: SystemActor.compute()
             )

    assert machine_id == vm.id and thread_id == thread.id and is_binary(session_id)

    stranger = %{c | actor: user()} |> thread() |> idle()

    assert {:error, _} =
             SSH.watch_subscribe(
               %{
                 gateway_token: c.gateway_token,
                 session_token: c.session_token,
                 machines: [],
                 threads: [thread.id, stranger.id]
               },
               actor: SystemActor.compute()
             )

    route = fn threads ->
      Marshall.SSH.ControlRequests.handle("watch_subscribe", c.gateway_token, %{
        "version" => 1,
        "session_token" => c.session_token,
        "machines" => [],
        "threads" => threads
      })
      |> Marshall.SSH.ControlRequests.classify()
    end

    assert {:ok, %{threads: [^thread_id]}} = route.([thread.id])
    assert {:error, 403, "forbidden"} = route.([stranger.id])
  end

  # @cc [owner:ghuntley,label:verification;durability] read-marker-never-decreases
  # Arbitrary sequences of mark-read positions MUST leave a marker equal to
  # the running maximum of the clamped positions, never smaller.
  test "read marker positions never decrease", c do
    thread = c |> thread() |> idle()
    for _ <- 1..4, do: append(thread, :assistant, %{"text" => "event"})
    [agent] = Ledger.read!(AgentThread, id: thread.agent_thread_id)
    last = agent |> events() |> List.last()

    Hegel.check(
      fn ->
        positions = draw("positions", list_of(integer(0..12), min_length: 1, max_length: 8))

        start =
          case Ledger.read!(ReadMarker, user_id: c.actor.id, agent_thread_id: agent.id) do
            [marker] -> marker.position
            [] -> 0
          end

        Enum.reduce(positions, start, fn position, previous ->
          assert {:ok, result} =
                   Threads.mark_read(%{thread_id: thread.id, position: position}, actor: c.actor)

          expected = max(previous, min(position, last))
          assert result.read_sequence == expected
          assert result.read_sequence >= previous
          assert result.unread == Enum.count(events(agent), &(&1 > expected))
          expected
        end)
      end,
      test_cases: 50,
      seed: 20_261_018,
      database: :disabled,
      print_blob: false
    )
  end

  test "thread and web results match the published client result fixture", c do
    thread = c |> thread() |> idle()
    append(thread, :assistant, %{"text" => "fixture"})
    machine(c, "fixture-box")
    expected = @fixture |> File.read!() |> JSON.decode!()

    observed = %{
      "thread ls" => command(c, "thread ls"),
      "thread show" => command(c, "thread show #{thread.id}"),
      "thread turns" => command(c, "thread turns #{thread.id}"),
      "thread read" => result(receipt(c, "thread read #{thread.id} 1 --request-id fx-read")),
      "thread mode" => result(receipt(c, "thread mode #{thread.id} plan --request-id fx-mode")),
      "web show" => command(c, "web show fixture-box"),
      "web set" => result(receipt(c, "web set fixture-box --port 8081 --request-id fx-web"))
    }

    for {name, {:ok, actual}} <- observed do
      example = Map.fetch!(expected["results"], name)
      assert_shape(name, example, actual)
    end

    thread_after_prompt = c |> thread() |> idle()

    assert {:ok, %{result: prompted}} =
             receipt(c, "thread prompt #{thread_after_prompt.id} - --request-id fx-p", "Go.")

    assert_shape("thread prompt", expected["results"]["thread prompt"], prompted)
  end

  # An empty example object marks a free-form document (event bodies).
  @spec assert_shape(String.t(), term(), term()) :: :ok
  defp assert_shape(name, example, actual) when example == %{} do
    assert is_map(actual), name
    :ok
  end

  defp assert_shape(name, example, actual) when is_map(example) do
    assert is_map(actual), name
    assert Enum.sort(Map.keys(example)) == Enum.sort(Map.keys(actual)), name

    Enum.each(example, fn {key, value} ->
      assert_shape(name <> "." <> key, value, Map.fetch!(actual, key))
    end)
  end

  defp assert_shape(name, [example | _], actual) do
    assert is_list(actual), name
    Enum.each(actual, &assert_shape(name <> "[]", example, &1))
  end

  defp assert_shape(_name, nil, _actual), do: :ok
  defp assert_shape(_name, _example, nil), do: :ok

  defp assert_shape(name, example, actual) do
    assert kind(example) == kind(actual), name
    :ok
  end

  @spec kind(term()) :: atom()
  defp kind(value) when is_binary(value), do: :string
  defp kind(value) when is_boolean(value), do: :boolean
  defp kind(value) when is_integer(value), do: :integer
  defp kind(value) when is_list(value), do: :list
  defp kind(value) when is_map(value), do: :map

  @spec result({:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  defp result({:ok, %{result: result}}), do: {:ok, result}
  defp result(other), do: other

  # Read commands return the result document; mutations return their receipt.
  @spec command(context(), String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  defp command(c, text, stdin \\ nil) do
    case execute(c, text, stdin) do
      {:ok, %{result: result}} -> {:ok, result}
      other -> other
    end
  end

  @spec receipt(context(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  defp receipt(c, text, stdin \\ nil), do: execute(c, text, stdin)

  defp execute(c, text, stdin) do
    {:ok, parsed} = SSHCommand.parse(text)

    parsed =
      case stdin do
        nil ->
          parsed

        bytes ->
          {:ok, supplied} = SSHCommand.put_stdin_payload(parsed, bytes)
          supplied
      end

    %{
      gateway_token: c.gateway_token,
      session_token: c.session_token,
      command: parsed |> Jason.encode!() |> Jason.decode!()
    }
    |> SSH.execute(actor: SystemActor.compute())
    |> case do
      {:ok, envelope} -> {:ok, strings(envelope)}
      {:error, error} -> {:error, reason(error)}
    end
  end

  @spec reason(term()) :: atom()
  defp reason(%{reason: reason}) when is_atom(reason), do: reason
  defp reason(%{errors: [error | _]}), do: reason(error)
  defp reason(error), do: Threads.error_reason(error)

  # Envelope keys are atoms; result documents keep their JSON string keys.
  defp strings(%{result: result} = envelope),
    do: %{envelope | result: result |> Jason.encode!() |> Jason.decode!()}

  defp strings(envelope), do: envelope

  @spec thread(context()) :: Thread.t()
  defp thread(c) do
    request = request()

    {:ok, thread} =
      Threads.create_thread(
        %{
          objective: "Improve the workspace",
          mode: :medium,
          machine_spec: request,
          idempotency_key: request.idempotency_key
        },
        actor: c.actor
      )

    host_fixture()
    args = %{"thread_id" => thread.id, "machine_key" => thread.machine_key}
    assert {:snooze, _} = ProvisionWorker.perform(%Oban.Job{args: args})
    [vm] = Ledger.read!(VirtualMachine, idempotency_key: thread.machine_key)
    Ledger.update!(vm, :observe, %{observed_state: :running})
    assert :ok = ProvisionWorker.perform(%Oban.Job{args: args})
    [ready] = Ledger.read!(Thread, id: thread.id)
    ready
  end

  @spec idle(Thread.t()) :: Thread.t()
  defp idle(thread) do
    Enum.each(Ledger.read!(Turn, thread_id: thread.agent_thread_id), &complete/1)
    thread
  end

  defp complete(%Turn{status: status} = turn) when status in [:queued, :running],
    do: Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})

  defp complete(turn), do: turn

  defp append(thread, kind, body) do
    [agent] = Ledger.read!(AgentThread, id: thread.agent_thread_id)
    next = agent.next_event_sequence

    event =
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: agent.id,
        sequence: next,
        kind: kind,
        body: body
      })

    Ledger.update!(agent, :advance, %{next_event_sequence: next + 1})
    event
  end

  @spec events(AgentThread.t()) :: [pos_integer()]
  defp events(agent) do
    Marshall.Agents.Event
    |> Ledger.read!(thread_id: agent.id)
    |> Enum.reject(&(&1.kind == :model_output))
    |> Enum.map(& &1.sequence)
    |> Enum.sort()
  end

  defp question(thread, actor) do
    {:ok, question} =
      Ledger.transaction(fn ->
        agent = Ledger.lock!(AgentThread, thread.agent_thread_id)
        ordinal = length(Ledger.read!(Turn, thread_id: agent.id)) + 1

        turn =
          Ledger.create!(Turn, :enqueue, %{
            thread_id: agent.id,
            actor_id: actor.id,
            request_key: Ash.UUID.generate(),
            ordinal: ordinal,
            prompt: "Choose the implementation approach.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        agent = Ledger.update!(agent, :set_context, %{collaboration_mode: :plan})
        agent = Ledger.update!(agent, :advance, %{active_turn_id: turn.id})

        Planning.request_questions_locked!(agent, turn, %{
          id: "client-question",
          arguments: %{
            "questions" => [
              %{
                "id" => "approach",
                "header" => "Approach",
                "question" => "Which approach should the plan use?",
                "options" => [
                  %{"label" => "First", "description" => "Keep the current interface."},
                  %{"label" => "Second", "description" => "Add a new interface."}
                ]
              }
            ]
          }
        })
      end)

    question
  end

  defp proposal(thread) do
    [turn | _] =
      Ledger.read!(Turn, thread_id: thread.agent_thread_id) |> Enum.sort_by(& &1.ordinal, :desc)

    text = "Inspect the route, implement the change, and verify the response."

    Ledger.create!(PlanProposal, :record, %{
      thread_id: thread.agent_thread_id,
      turn_id: turn.id,
      event_sequence: 2,
      text: text,
      digest: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    })
  end

  defp machine(c, name) do
    previous = Application.fetch_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, image_id())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :default_image_id, value)
        :error -> Application.delete_env(:marshall, :default_image_id)
      end
    end)

    assert {:ok, %{operation_id: operation}} =
             receipt(c, "new --name #{name} --request-id create-#{name}")

    [op] = Ledger.read!(Marshall.Compute.Operation, id: operation)
    [vm] = Ledger.read!(VirtualMachine, id: op.vm_id)
    vm
  end

  defp public_key(bytes) do
    blob = <<11::32, "ssh-ed25519", 32::32, bytes::binary>>
    "ssh-ed25519 " <> Base.encode64(blob)
  end
end
