defmodule Lilly.VM.WorkspaceSourceTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import ExUnit.CaptureLog
  alias Lilly.VM.WorkspaceSource

  # Unix socket paths are limited to 107 bytes, so fixtures use a short root.
  setup do
    root = Path.join(System.tmp_dir!(), "ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tmp_dir: root}
  end

  @type behaviour :: :normal | :refuse | :ack_lost | :bad_nonce

  # A fake guest agent behind a fake Firecracker jail socket. It verifies the
  # boot binding against its own "kernel command line", stores at most one
  # source on its "disk" and records every request and accepted reply.
  defmodule Guest do
    @moduledoc false

    @spec start(Path.t(), map()) :: {pid(), pid()}
    def start(path, boot) do
      {:ok, state} =
        Agent.start_link(fn ->
          %{boot: boot, stored: nil, queue: [], requests: [], accepted: [], connections: 0}
        end)

      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          ip: {:local, path},
          packet: :line,
          packet_size: 8192,
          buffer: 8192
        ])

      acceptor = spawn_link(fn -> accept(listener, state) end)
      {state, acceptor}
    end

    defp accept(listener, state) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          serve(socket, state)
          :gen_tcp.close(socket)
          accept(listener, state)

        _ ->
          :ok
      end
    end

    defp serve(socket, state) do
      behaviour =
        Agent.get_and_update(state, fn value ->
          value = %{value | connections: value.connections + 1}

          case value.queue do
            [next | rest] -> {next, %{value | queue: rest}}
            [] -> {:normal, value}
          end
        end)

      with {:ok, "CONNECT 1031\n"} <- :gen_tcp.recv(socket, 0, 2000),
           false <- behaviour == :refuse,
           :ok <- :gen_tcp.send(socket, "OK 1073741824\n"),
           {:ok, line} <- :gen_tcp.recv(socket, 0, 2000),
           {:ok, request} <- JSON.decode(line) do
        Agent.update(state, &%{&1 | requests: &1.requests ++ [request]})
        respond(socket, state, behaviour, request)
      end
    end

    defp respond(socket, state, behaviour, request) do
      boot = Agent.get(state, & &1.boot)

      binding =
        Map.take(request, ["placement_id", "execution_epoch", "boot_challenge"]) ==
          %{
            "placement_id" => boot.placement_id,
            "execution_epoch" => boot.execution_epoch,
            "boot_challenge" => boot.boot_challenge
          }

      cond do
        not binding ->
          :refused

        behaviour == :bad_nonce ->
          reply(socket, request, "accepted", String.duplicate("0", 64))

        true ->
          source = request["source"]

          verdict =
            Agent.get_and_update(state, fn value ->
              cond do
                value.stored in [nil, source] ->
                  {"accepted",
                   %{
                     value
                     | stored: source,
                       accepted: value.accepted ++ [{request["execution_epoch"], source}]
                   }}

                true ->
                  {"conflict", value}
              end
            end)

          if behaviour != :ack_lost, do: reply(socket, request, verdict, request["nonce"])
      end
    end

    defp reply(socket, request, state, nonce) do
      body =
        request
        |> Map.take(["placement_id", "execution_epoch", "boot_challenge"])
        |> Map.merge(%{"version" => 1, "state" => state, "nonce" => nonce})

      :gen_tcp.send(socket, JSON.encode!(body) <> "\n")
    end
  end

  defp boot(epoch, placement \\ "11111111-1111-4111-8111-111111111111") do
    %{
      placement_id: placement,
      execution_epoch: epoch,
      generation: 1,
      boot_challenge: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }
  end

  @spec source_gen() :: Hegel.Gen.t(OverallsProtocol.WorkspaceSource.t())
  defp source_gen do
    alnum = Enum.concat([?a..?z, ?A..?Z, ?0..?9])

    gen all(
          provider <- member_of([:github, :gitlab, :codeberg, :bitbucket]),
          namespace <- string(alnum, min_length: 1, max_length: 39),
          repository <- string(alnum, min_length: 1, max_length: 100),
          revision <-
            one_of([
              constant(%{kind: :default}),
              map(string(alnum, min_length: 1, max_length: 255), &%{kind: :ref, value: &1}),
              map(string(Enum.concat(?0..?9, ?a..?f), length: 40), &%{kind: :commit, value: &1}),
              map(integer(1..2_147_483_647), &%{kind: :change, value: &1})
            ])
        ) do
      namespace = if provider == :gitlab, do: [namespace, "nested"], else: [namespace]
      %{provider: provider, namespace: namespace, repository: repository, revision: revision}
    end
  end

  defp expectation(boot), do: Map.take(boot, [:placement_id, :execution_epoch, :boot_challenge])

  test "a maximal request line is within 4096 bytes and has exactly the contract keys" do
    boot = boot(9_223_372_036_854_775_807)
    nonce = String.duplicate("f", 64)

    for source <- [
          %{
            provider: :gitlab,
            namespace: [String.duplicate("a", 100), String.duplicate("g", 100)],
            repository: String.duplicate("r", 100),
            revision: %{
              kind: :ref,
              value: String.duplicate("b", 60) <> "/" <> String.duplicate("@+=,._-", 27) <> "z"
            }
          },
          %{
            provider: :github,
            namespace: ["o"],
            repository: String.duplicate("r", 100),
            revision: %{kind: :commit, value: String.duplicate("a", 40)}
          },
          %{
            provider: :codeberg,
            namespace: ["o"],
            repository: "r",
            revision: %{kind: :change, value: 2_147_483_647}
          },
          %{provider: :bitbucket, namespace: ["o"], repository: "r", revision: %{kind: :default}}
        ] do
      assert OverallsProtocol.WorkspaceSource.valid?(source)
      assert {:ok, line} = WorkspaceSource.request(expectation(boot), nonce, source)
      assert byte_size(line) <= 4096
      assert String.ends_with?(line, "\n")
      refute String.contains?(String.trim_trailing(line, "\n"), "\n")
      decoded = JSON.decode!(line)

      assert Enum.sort(Map.keys(decoded)) ==
               ~w(boot_challenge execution_epoch nonce placement_id source version)

      assert decoded["version"] == 1
      assert decoded["placement_id"] == boot.placement_id
      assert decoded["execution_epoch"] == boot.execution_epoch
      assert decoded["boot_challenge"] == boot.boot_challenge
      assert decoded["nonce"] == nonce

      assert Enum.sort(Map.keys(decoded["source"])) ==
               ~w(namespace provider repository revision version)

      assert decoded["source"]["version"] == 2
      assert {:ok, ^source} = OverallsProtocol.WorkspaceSource.decode(decoded["source"])
    end

    assert :error =
             WorkspaceSource.request(expectation(boot), "short", %{
               provider: :github,
               namespace: ["o"],
               repository: "r",
               revision: %{kind: :default}
             })

    assert :error =
             WorkspaceSource.request(expectation(boot), nonce, %{
               provider: :github,
               namespace: ["-o"],
               repository: "r",
               revision: %{kind: :default}
             })
  end

  property "generated sources always encode within the request bound" do
    check all(source <- source_gen(), max_runs: 200) do
      assert {:ok, line} =
               WorkspaceSource.request(expectation(boot(1)), String.duplicate("a", 64), source)

      assert byte_size(line) <= 4096
    end
  end

  property "only an exact echo of binding and nonce is accepted" do
    expected = expectation(boot(5))
    nonce = String.duplicate("a", 64)

    good = %{
      "version" => 1,
      "state" => "accepted",
      "placement_id" => expected.placement_id,
      "execution_epoch" => expected.execution_epoch,
      "boot_challenge" => expected.boot_challenge,
      "nonce" => nonce
    }

    assert :accepted = WorkspaceSource.reply(JSON.encode!(good) <> "\n", expected, nonce)

    assert :conflict =
             WorkspaceSource.reply(
               JSON.encode!(%{good | "state" => "conflict"}) <> "\n",
               expected,
               nonce
             )

    refute WorkspaceSource.reply(JSON.encode!(good), expected, nonce) == :accepted

    check all(
            key <- member_of(Map.keys(good)),
            value <- one_of([integer(), constant(nil), string(:alphanumeric, max_length: 70)]),
            value != good[key]
          ) do
      assert :rejected =
               WorkspaceSource.reply(
                 JSON.encode!(Map.put(good, key, value)) <> "\n",
                 expected,
                 nonce
               )

      assert :rejected =
               WorkspaceSource.reply(
                 JSON.encode!(Map.put(good, "extra", value)) <> "\n",
                 expected,
                 nonce
               )
    end
  end

  # Model-based command sequences. The model mirrors Driver.deliver_workspace_source/4:
  # a boot whose journal is settled is never redelivered, each delivery runs in the
  # supervised task via start/2 and the fence compares the model's current boot.
  property "delivery command sequences keep boot binding, conflict and readiness invariants",
           %{tmp_dir: root} do
    commands =
      list_of(
        member_of([
          :deliver,
          :ack_lost,
          :connect_refused,
          :reply_conflict,
          :reply_mismatched_nonce,
          :new_epoch
        ]),
        min_length: 1,
        max_length: 8
      )

    check all(
            source <- source_gen(),
            other <- source_gen(),
            other != source,
            sequence <- commands,
            max_runs: 20
          ) do
      path = Path.join(root, "#{System.unique_integer([:positive])}.sock")
      first = boot(1, Lilly.UUID.generate())
      {guest, acceptor} = Guest.start(path, first)
      digest = WorkspaceSource.digest(source)

      model = %{boot: first, journal: nil, delivered: []}

      final =
        Enum.reduce(sequence, model, fn command, model ->
          run(command, model, %{
            path: path,
            guest: guest,
            source: source,
            other: other,
            digest: digest
          })
        end)

      requests = Agent.get(guest, & &1.requests)
      accepted = Agent.get(guest, & &1.accepted)

      # Every request carries a fresh nonce.
      nonces = Enum.map(requests, & &1["nonce"])
      assert length(Enum.uniq(nonces)) == length(nonces)

      # At most one accepted source per placement/epoch, and never a foreign one.
      accepted
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.each(fn {_epoch, sources} -> assert length(Enum.uniq(sources)) == 1 end)

      # Lilly settles a boot once: no epoch is delivered (accepted) twice.
      assert length(Enum.uniq(final.delivered)) == length(final.delivered)

      if final.journal && final.journal["state"] == "delivered" do
        assert final.journal["execution_epoch"] in final.delivered
        assert final.journal["execution_epoch"] <= final.boot.execution_epoch
      end

      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
      Agent.stop(guest)
    end
  end

  defp run(:new_epoch, model, context) do
    stale = model.boot
    fresh = boot(stale.execution_epoch + 1, stale.placement_id)
    Agent.update(context.guest, &%{&1 | boot: fresh, queue: []})
    before = Agent.get(context.guest, &length(&1.requests))

    # A delivery still holding the superseded boot: the fence reports the new boot, so
    # the stale binding is never sent and nothing is recorded as delivered.
    assert {:error, :workspace_source_fenced} =
             deliver(context, stale, fn -> if(fresh == stale, do: :ok, else: {:error, :stale}) end)

    assert Agent.get(context.guest, &length(&1.requests)) == before

    # Even if a stale request races past the host fence, the guest refuses the old
    # binding and the host never counts it as accepted.
    Agent.update(context.guest, &%{&1 | queue: []})
    raced = Agent.get(context.guest, & &1.accepted)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    fence = fn ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: :ok, else: {:error, :stale}
    end

    assert {:error, :workspace_source_fenced} = deliver(context, stale, fence)
    Agent.stop(calls)
    assert Agent.get(context.guest, & &1.accepted) == raced

    %{model | boot: fresh}
  end

  defp run(command, model, context) do
    if WorkspaceSource.settled?(model.journal, model.boot, context.digest) do
      model
    else
      guest_before = Agent.get(context.guest, & &1)

      case command do
        :ack_lost ->
          Agent.update(context.guest, &%{&1 | queue: [:ack_lost]})

        :connect_refused ->
          Agent.update(context.guest, &%{&1 | queue: [:refuse, :refuse]})

        :reply_mismatched_nonce ->
          Agent.update(context.guest, &%{&1 | queue: [:bad_nonce]})

        :reply_conflict ->
          Agent.update(context.guest, &%{&1 | stored: &1.stored || context.other})

        :deliver ->
          :ok
      end

      stored = Agent.get(context.guest, & &1.stored)
      current = model.boot

      result =
        deliver(context, current, fn ->
          if(model.boot == current, do: :ok, else: {:error, :stale})
        end)

      guest_after = Agent.get(context.guest, & &1)
      attempts = guest_after.connections - guest_before.connections

      cond do
        command == :reply_mismatched_nonce ->
          assert result == {:error, :workspace_source_rejected}
          assert attempts == 1

        stored not in [nil, OverallsProtocol.WorkspaceSource.encode(context.source)] ->
          # A different stored source is terminal: no retry after the conflict reply.
          # Queued transport failures (a lost acknowledgement, two refused connects)
          # are retried before that single conflict reply arrives.
          assert result == {:error, :workspace_source_conflict}
          assert attempts == 1 + Map.get(%{ack_lost: 1, connect_refused: 2}, command, 0)
          assert guest_after.stored == stored

        true ->
          assert result == :ok
          if command == :ack_lost, do: assert(attempts >= 2)
          if command == :connect_refused, do: assert(attempts >= 3)
          assert guest_after.stored == OverallsProtocol.WorkspaceSource.encode(context.source)
      end

      state = if result == :ok, do: :delivered, else: :failed

      %{
        model
        | journal:
            WorkspaceSource.payload(
              Lilly.UUID.generate(),
              current,
              state,
              1,
              context.digest
            ),
          delivered:
            if(result == :ok,
              do: [current.execution_epoch | model.delivered],
              else: model.delivered
            )
      }
    end
  end

  # Runs one delivery the way the executor does: start/2 must return at once, the
  # caller's running observation is produced before delivery finishes, and the
  # delivery result arrives later from the supervised task.
  defp deliver(context, boot, fence) do
    parent = self()
    ref = make_ref()
    gate = make_ref()
    wait_idle(boot.placement_id)
    started = System.monotonic_time(:millisecond)

    assert :ok =
             WorkspaceSource.start(boot.placement_id, fn ->
               receive do
                 ^gate -> :ok
               after
                 5000 -> :ok
               end

               result =
                 WorkspaceSource.deliver(context.path, expectation(boot), context.source,
                   timeout: 3000,
                   backoff: 5,
                   fence: fence
                 )

               send(parent, {ref, result})
             end)

    # The delivery task is blocked on the gate, yet start/2 has already returned
    # and the placement reports one in-flight delivery.
    assert System.monotonic_time(:millisecond) - started < 1000
    assert wait_registered(boot.placement_id)
    assert :already_running = WorkspaceSource.start(boot.placement_id, fn -> :ok end)
    [{task, _}] = Registry.lookup(Lilly.VM.WorkspaceSource.Registry, boot.placement_id)
    refute task in (Process.info(self(), :links) |> elem(1))
    send(task, gate)

    receive do
      {^ref, result} -> result
    after
      10_000 -> flunk("delivery did not finish")
    end
  end

  defp wait_registered(placement, attempts \\ 200) do
    cond do
      WorkspaceSource.in_flight?(placement) -> true
      attempts == 0 -> false
      true -> Process.sleep(5) && wait_registered(placement, attempts - 1)
    end
  end

  defp wait_idle(placement, attempts \\ 200) do
    if WorkspaceSource.in_flight?(placement) and attempts > 0 do
      Process.sleep(5)
      wait_idle(placement, attempts - 1)
    end
  end

  test "a crashing delivery task never reaches the caller", %{tmp_dir: _root} do
    placement = Lilly.UUID.generate()

    capture_log(fn ->
      parent = self()

      assert :ok =
               WorkspaceSource.start(placement, fn ->
                 send(parent, :started)
                 raise "synthetic delivery crash"
               end)

      assert_receive :started, 1000
      wait_idle(placement)
    end)

    assert Process.alive?(self())
    refute WorkspaceSource.in_flight?(placement)
  end

  test "an absent guest exhausts only the bounded budget", %{tmp_dir: root} do
    started = System.monotonic_time(:millisecond)

    assert {:error, :workspace_source_unconfirmed} =
             WorkspaceSource.deliver(
               Path.join(root, "absent.sock"),
               expectation(boot(1)),
               %{
                 provider: :github,
                 namespace: ["o"],
                 repository: "r",
                 revision: %{kind: :default}
               },
               timeout: 200,
               backoff: 10
             )

    assert System.monotonic_time(:millisecond) - started < 1000
  end
end
