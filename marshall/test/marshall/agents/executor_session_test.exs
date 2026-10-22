defmodule Marshall.Agents.ExecutorSessionTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Agents.{
    AuditEvent,
    Command,
    ExecutorRPC,
    ExecutorSession,
    Root,
    Thread,
    Turn
  }

  alias Marshall.Compute
  alias Marshall.Compute.{Host, HostReports, Ledger, Operation, Outcomes}
  alias Marshall.Inference.Credentials

  # @cc [owner:ghuntley,label:verification;security] executor-rpc-current-host-fixture
  # Authenticated bootstrap claims MUST exercise a real current provisioner
  # session and fresh report, not bypass host-liveness authority with seeded fields.
  setup do
    fixture = host_fixture()
    {:ok, credential} = Marshall.Compute.Credentials.rotate(fixture.host.id, 3600)

    {:ok, session} =
      Marshall.Compute.ProvisionerControl.open_execution(credential.token, %{
        session_id: Ash.UUID.generate(),
        machine_id: fixture.host.machine_id
      })

    {:ok, _} =
      Marshall.Compute.ProvisionerControl.exchange_execution(credential.token, %{
        session_id: session["session_id"],
        epoch: session["epoch"],
        report: fixture.report,
        acknowledgements: [],
        outcomes: []
      })

    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    {:ok, parsed} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Host, vm.host_id)
        Outcomes.ingest_locked!(vm.host_id, [parsed])
      end)

    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)

    binding = %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch
    }

    %{
      actor: actor,
      binding: binding,
      connection_epoch: session["epoch"],
      root: root,
      thread: thread,
      vm: vm
    }
  end

  test "replacement fences stale results and preserves an ambiguous tool as uncertain", c do
    {:ok, first} = ExecutorSession.register(c.binding)

    turn =
      Ledger.create!(Turn, :enqueue, %{
        thread_id: c.thread.id,
        actor_id: c.actor.id,
        request_key: Ash.UUID.generate(),
        ordinal: 1,
        prompt: "run command"
      })

    Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
    Ledger.update!(c.thread, :advance, %{active_turn_id: turn.id})

    command =
      Ledger.create!(Command, :queue, %{
        root_id: c.root.id,
        thread_id: c.thread.id,
        turn_id: turn.id,
        call_id: "call-1",
        tool: :exec_command,
        arguments: %{"cmd" => "touch marker"}
      })

    assert {:ok, %{id: id, status: :claimed}} =
             ExecutorSession.claim(c.binding, first.id, first.fence_epoch)

    assert id == command.id

    assert {:ok, %{status: :started}} =
             ExecutorSession.transition(
               c.binding,
               first.id,
               first.fence_epoch,
               command.id,
               :started
             )

    assert {:ok, second} = ExecutorSession.register(c.binding)
    assert second.fence_epoch == first.fence_epoch + 1
    assert [%{status: :uncertain}] = Ledger.read!(Command, id: command.id)

    assert {:error, _} =
             ExecutorSession.transition(
               c.binding,
               first.id,
               first.fence_epoch,
               command.id,
               :completed
             )

    assert {:ok, nil} = ExecutorSession.claim(c.binding, second.id, second.fence_epoch)
    assert [%{kind: :tool_dispatched}] = Ledger.read!(AuditEvent, target_id: command.id)
  end

  test "binary digest registration is persisted and produces a content-free update audit", c do
    first_digest = String.duplicate("a", 64)
    second_digest = String.duplicate("b", 64)
    {:ok, first} = ExecutorSession.register(c.binding, first_digest)
    assert first.binary_sha256 == first_digest

    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret

    assert {:ok, %{executor_id: second_id}} =
             ExecutorRPC.request(token, "register", %{
               "binding" => c.binding,
               "digest" => second_digest
             })

    assert [%{binary_sha256: ^second_digest}] =
             Ledger.read!(Marshall.Agents.Executor, id: second_id)

    assert [%{kind: :executor_updated, outcome: :accepted, target_id: ^second_id}] =
             Ledger.read!(AuditEvent, target_id: second_id)

    assert {:error, :invalid_request} =
             ExecutorRPC.request(token, "register", %{
               "binding" => c.binding,
               "digest" => "not-a-digest"
             })
  end

  test "forged placement and host bindings cannot register a lease", c do
    for field <- ["host_id", "placement_id", "execution_epoch"] do
      value = if field == "execution_epoch", do: 999, else: Ash.UUID.generate()
      assert {:error, _} = ExecutorSession.register(Map.put(c.binding, field, value))
    end
  end

  test "host credential authenticates guest RPC while binding and lease fence remain authoritative",
       c do
    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret

    assert {:ok, %{executor_id: id, fence_epoch: fence}} =
             ExecutorRPC.request(token, "register", %{"binding" => c.binding})

    assert {:ok, %{expires_at_ms: expiry}} =
             ExecutorRPC.request(token, "heartbeat", %{
               "binding" => c.binding,
               "executor_id" => id,
               "fence_epoch" => fence
             })

    assert is_integer(expiry)

    assert {:ok, %{command: nil}} =
             ExecutorRPC.request(token, "claim", %{
               "binding" => c.binding,
               "executor_id" => id,
               "fence_epoch" => fence
             })

    assert {:error, _} =
             ExecutorRPC.request(token, "register", %{
               "binding" => Map.put(c.binding, "host_id", Ash.UUID.generate())
             })

    assert {:error, _} =
             ExecutorRPC.request(String.duplicate("x", 80), "register", %{"binding" => c.binding})

    assert {:error, :invalid_request} =
             ExecutorRPC.request(token, "transition", %{
               "binding" => c.binding,
               "executor_id" => id,
               "fence_epoch" => fence,
               "command_id" => Ash.UUID.generate(),
               "status" => "other"
             })

    assert {:ok, :ok} = HostReports.disconnect(c.vm.host_id, c.connection_epoch)

    assert {:error, :unauthorized} =
             ExecutorRPC.request(token, "claim", %{
               "binding" => c.binding,
               "executor_id" => id,
               "fence_epoch" => fence
             })
  end

  test "Ziggy's control socket registers an executor without leaking its token", c do
    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret
    {:ok, principal} = Marshall.Control.Services.Ziggy.authenticate(token)

    assert {:ok, %{"executor_id" => _, "fence_epoch" => 1, "expires_at_ms" => _} = response} =
             Marshall.Control.Services.Ziggy.handle_request(
               "ziggy.agent_register",
               %{"version" => 2, "binding" => c.binding},
               principal
             )

    refute String.contains?(JSON.encode!(response), token)
  end

  test "registration stores a closed capability set and omission advertises no new operations",
       c do
    assert {:ok, %{capabilities: []}} = ExecutorSession.register(c.binding)
    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret

    assert {:ok, %{executor_id: id}} =
             ExecutorRPC.request(token, "register", %{
               "binding" => c.binding,
               "capabilities" => ["skills-v1", "context-v1"]
             })

    assert [%{capabilities: ["context-v1", "skills-v1"]}] =
             Ledger.read!(Marshall.Agents.Executor, id: id)

    for capabilities <- [nil, "context-v1", ["context-v2"], ["context-v1", "context-v1"], [1]] do
      assert {:error, :invalid_request} =
               ExecutorRPC.request(token, "register", %{
                 "binding" => c.binding,
                 "capabilities" => capabilities
               })
    end
  end

  # The current Lyra executor (lyra/src/agent.rs) advertises every capability
  # Marshall accepts; the stored set must admit all of them at once.
  test "registration admits the full capability set a current executor advertises", c do
    advertised = ["context-v1", "skills-v1", "github-tools-v1", "artifacts-v1"]
    assert ExecutorSession.valid_capabilities?(advertised)

    assert {:ok, %{capabilities: stored}} =
             ExecutorSession.register(c.binding, nil, advertised)

    assert stored == Enum.sort(advertised)
  end

  test "an old guest receives no internal command and its refusal is durable", c do
    {:ok, executor} = ExecutorSession.register(c.binding)
    command = internal_command(c, :context_inventory, %{"version" => 1})
    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    assert [
             %{
               status: :failed,
               executor_id: nil,
               result: %{"reason" => "executor_upgrade_required"}
             }
           ] =
             Ledger.read!(Command, id: command.id)

    assert [%{kind: :tool_finished, outcome: :failed}] =
             Ledger.read!(AuditEvent, target_id: command.id)

    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)
    assert length(Ledger.read!(AuditEvent, target_id: command.id)) == 1
  end

  for tool <- [:thread] do
    test "guest claims leave #{tool} commands queued", c do
      {:ok, executor} = ExecutorSession.register(c.binding)
      command = internal_command(c, unquote(tool), %{"operation" => "download"})
      assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)
      assert [%{status: :queued, executor_id: nil}] = Ledger.read!(Command, id: command.id)
    end
  end

  test "capable guest claims upload commands while server worker leaves them queued", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["attachments-v1"])

    command =
      internal_command(c, :attachment, %{
        "operation" => "upload",
        "thread_id" => Ecto.UUID.generate(),
        "idempotency_key" => "guest",
        "path" => "/tmp/input"
      })

    run_server_tools!()
    assert [%{status: :queued}] = Ledger.read!(Command, id: command.id)
    id = command.id

    assert {:ok, %{id: ^id, status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)
  end

  test "capable guest claims downloads while server worker leaves them queued", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["attachments-v1"])

    command =
      internal_command(c, :attachment, %{
        "operation" => "download",
        "attachment_id" => Ecto.UUID.generate(),
        "path" => "/tmp/output"
      })

    run_server_tools!()
    assert [%{status: :queued}] = Ledger.read!(Command, id: command.id)
    id = command.id

    assert {:ok, %{id: ^id, status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)
  end

  test "guest upload requires a current started command and retains metadata only", c do
    {:ok, target_thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "Attachment integration test",
          mode: :medium,
          machine_spec: %{
            architecture: :x86_64,
            profile: :standard,
            image_id: "sha256:" <> String.duplicate("a", 64),
            vcpu: 2,
            memory_bytes: 4_294_967_296,
            disk_bytes: 42_949_672_960,
            team_id: nil
          },
          idempotency_key: Ecto.UUID.generate()
        },
        actor: c.actor
      )

    store = Marshall.Agents.AttachmentStore
    previous = Application.get_env(:marshall, store)
    root = Path.join(System.tmp_dir!(), "executor-attachment-#{Ecto.UUID.generate()}")

    Application.put_env(:marshall, store,
      root: root,
      encryption_key: :crypto.strong_rand_bytes(32)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, store, previous),
        else: Application.delete_env(:marshall, store)

      File.rm_rf!(root)
    end)

    {:ok, executor} = ExecutorSession.register(c.binding)

    command =
      internal_command(c, :attachment, %{
        "operation" => "upload",
        "thread_id" => target_thread.id,
        "idempotency_key" => "guest-transfer",
        "path" => "/tmp/input.bin"
      })

    assert {:error, :stale_fence} =
             ExecutorSession.attachment_upload(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               "private guest bytes"
             )

    Ledger.update!(command, :transition, %{
      status: :started,
      executor_id: executor.id,
      fence_epoch: executor.fence_epoch
    })

    assert {:ok, %{id: id}} =
             ExecutorSession.attachment_upload(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               "private guest bytes"
             )

    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret

    transfer = %{
      "binding" => c.binding,
      "executor_id" => executor.id,
      "fence_epoch" => executor.fence_epoch,
      "command_id" => command.id,
      "content_base64" => Base.encode64("private guest bytes")
    }

    assert {:ok, %{id: ^id}} =
             Marshall.Inference.ControlRequests.handle(
               "agent_attachment_upload",
               token,
               transfer
             )

    assert {:error, :invalid_request} =
             ExecutorRPC.request(
               token,
               "attachment_upload",
               Map.put(transfer, "unexpected", true)
             )

    assert {:error, :invalid_request} =
             ExecutorRPC.request(
               token,
               "attachment_upload",
               Map.put(transfer, "content_base64", "invalid!")
             )

    assert {:error, _} = ExecutorRPC.request("invalid-token", "attachment_upload", transfer)
    [persisted] = Ledger.read!(Command, id: command.id)
    refute Map.has_key?(persisted.arguments, "content_base64")
    assert persisted.result == nil
    [attachment] = Ledger.read!(Marshall.Agents.Attachment, id: id)
    assert {:ok, "private guest bytes"} = store.get(attachment.storage_key)

    assert {:ok, %{id: ^id}} =
             ExecutorSession.attachment_upload(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               "private guest bytes"
             )

    chunk_command =
      Ledger.create!(Command, :queue, %{
        root_id: c.root.id,
        thread_id: c.thread.id,
        turn_id: command.turn_id,
        call_id: "chunk-transfer",
        tool: :attachment,
        arguments: %{
          "operation" => "upload",
          "thread_id" => target_thread.id,
          "idempotency_key" => "chunk-transfer",
          "path" => "/tmp/chunks"
        }
      })

    Ledger.update!(chunk_command, :transition, %{
      status: :started,
      executor_id: executor.id,
      fence_epoch: executor.fence_epoch
    })

    base = %{
      "binding" => c.binding,
      "executor_id" => executor.id,
      "fence_epoch" => executor.fence_epoch,
      "command_id" => chunk_command.id
    }

    digest = Base.encode16(:crypto.hash(:sha256, "data"), case: :lower)

    assert {:ok, %{id: chunk_id}} =
             ExecutorRPC.request(
               token,
               "attachment_transfer",
               Map.put(base, "transfer", %{
                 "phase" => "begin",
                 "size_bytes" => 4,
                 "sha256" => digest
               })
             )

    assert {:error, :invalid_request} =
             ExecutorRPC.request(
               token,
               "attachment_transfer",
               Map.put(base, "transfer", %{"phase" => "finish", "attachment_id" => id})
             )

    assert {:ok, _} =
             ExecutorRPC.request(
               token,
               "attachment_transfer",
               Map.put(base, "transfer", %{
                 "phase" => "chunk",
                 "attachment_id" => chunk_id,
                 "offset" => 0,
                 "content_base64" => Base.encode64("data")
               })
             )

    assert {:ok, %{state: :available}} =
             ExecutorRPC.request(
               token,
               "attachment_transfer",
               Map.put(base, "transfer", %{"phase" => "finish", "attachment_id" => chunk_id})
             )

    download_command =
      Ledger.create!(Command, :queue, %{
        root_id: c.root.id,
        thread_id: c.thread.id,
        turn_id: command.turn_id,
        call_id: "chunk-download",
        tool: :attachment,
        arguments: %{
          "operation" => "download",
          "attachment_id" => chunk_id,
          "path" => "/tmp/output"
        }
      })

    Ledger.update!(download_command, :transition, %{
      status: :started,
      executor_id: executor.id,
      fence_epoch: executor.fence_epoch
    })

    download_base = Map.put(base, "command_id", download_command.id)

    assert {:ok, %{content_base64: "ZGF0YQ==", offset: 0, size_bytes: 4}} =
             ExecutorRPC.request(
               token,
               "attachment_transfer",
               Map.put(download_base, "transfer", %{"phase" => "read", "offset" => 0})
             )

    assert {:error, :invalid_chunk} =
             ExecutorRPC.request(
               token,
               "attachment_transfer",
               Map.put(download_base, "transfer", %{"phase" => "read", "offset" => 1})
             )

    assert {:error, :invalid_request} =
             ExecutorRPC.request(
               token,
               "attachment_transfer",
               Map.put(base, "transfer", %{"phase" => "read", "offset" => 0})
             )

    metadata = %{"id" => chunk_id, "state" => "available", "size_bytes" => 4, "sha256" => digest}

    assert {:error, :invalid_result} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               download_command.id,
               :completed,
               Map.put(metadata, "content_base64", "ZGF0YQ==")
             )

    assert {:error, :invalid_result} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               download_command.id,
               :completed,
               Map.put(metadata, "id", id)
             )

    assert [%{status: :started, result: nil}] = Ledger.read!(Command, id: download_command.id)

    assert {:ok, %{status: :completed}} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               download_command.id,
               :completed,
               metadata
             )

    {:ok, _replacement} = ExecutorSession.register(c.binding)

    assert {:error, :stale_fence} =
             ExecutorSession.attachment_upload(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               "private guest bytes"
             )
  end

  test "board tools execute on the server with derived thread attribution and audit", c do
    user_thread =
      Ledger.create!(Marshall.Threads.Thread, :open, %{
        creator_id: c.actor.id,
        objective: "Coordinate",
        mode: :medium,
        machine_spec: request(),
        idempotency_key: Ash.UUID.generate(),
        machine_key: c.vm.idempotency_key
      })

    user_thread =
      Marshall.ThreadStateFixture.ready!(user_thread, %{
        machine_id: c.vm.id,
        agent_root_id: c.root.id,
        agent_thread_id: c.thread.id
      })

    command =
      internal_command(c, :message_board, %{
        "operation" => "post",
        "body" => "coordination content",
        "idempotency_key" => "post"
      })

    {:ok, executor} = ExecutorSession.register(c.binding)
    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)
    run_server_tools!()
    assert [%{status: :completed}] = Ledger.read!(Command, id: command.id)

    assert [%{kind: :tool_finished, outcome: :completed}] =
             Ledger.read!(AuditEvent, target_id: command.id)

    [post] = Marshall.MessageBoards.list!(c.actor.id, c.vm.profile)
    assert post.vm_id == c.vm.id
    assert post.thread_id == user_thread.id
    assert post.root_id == c.root.id

    listing =
      Ledger.create!(Command, :queue, %{
        root_id: c.root.id,
        thread_id: c.thread.id,
        turn_id: command.turn_id,
        call_id: "board-list",
        tool: :message_board,
        arguments: %{"operation" => "list"}
      })

    run_server_tools!()

    assert [%{status: :completed, result: %{"items" => [item]}}] =
             Ledger.read!(Command, id: listing.id)

    assert item["thread_url"] == "/threads/" <> user_thread.id
    assert item["body"] == "coordination content"
    assert Marshall.MessageBoards.list!(user().id, c.vm.profile) == []
  end

  test "subscribe commands register a durable agent receiver", c do
    target =
      Ledger.create!(Marshall.Threads.Thread, :open, %{
        creator_id: c.actor.id,
        objective: "Subscribe",
        mode: :medium,
        machine_spec: request(),
        idempotency_key: Ash.UUID.generate(),
        machine_key: c.vm.idempotency_key
      })

    target =
      Marshall.ThreadStateFixture.ready!(target, %{
        machine_id: c.vm.id,
        agent_root_id: c.root.id,
        agent_thread_id: c.thread.id
      })

    command =
      internal_command(c, :thread, %{"operation" => "subscribe", "thread_id" => target.id})

    run_server_tools!()
    assert [%{status: :completed}] = Ledger.read!(Command, id: command.id)

    assert [%{destination_kind: :user_thread, destination_id: id, state: :active}] =
             Ledger.read!(Marshall.Agents.ThreadReceiver)

    assert id == target.id

    child =
      Ledger.create!(Thread, :open, %{
        root_id: c.root.id,
        parent_thread_id: c.thread.id,
        title: "Subscribed child",
        created_by_id: c.actor.id
      })

    child_command = struct(Command, %{root_id: c.root.id, thread_id: child.id})

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Marshall.Agents.ThreadDelivery.register(child_command, c.actor.id, target.id, true)
             end)

    unsubscribe =
      Ledger.create!(Command, :queue, %{
        root_id: c.root.id,
        thread_id: c.thread.id,
        turn_id: command.turn_id,
        call_id: "unsubscribe",
        tool: :thread,
        arguments: %{"operation" => "subscribe", "thread_id" => target.id, "active" => false}
      })

    run_server_tools!()
    assert [%{status: :completed}] = Ledger.read!(Command, id: unsubscribe.id)

    assert [%{state: :inactive}] =
             Ledger.read!(Marshall.Agents.ThreadReceiver, destination_id: target.id)

    assert [%{state: :active}] =
             Ledger.read!(Marshall.Agents.ThreadReceiver, destination_id: child.id)

    assert {:error, :not_subscribed} =
             Marshall.Agents.ThreadDelivery.replay(command, c.actor.id, %{
               "thread_id" => target.id
             })

    assert {:ok, []} =
             Marshall.Agents.ThreadDelivery.replay(child_command, c.actor.id, %{
               "thread_id" => target.id
             })
  end

  test "malformed thread targets finish with a content-free refusal", c do
    command =
      internal_command(c, :thread, %{
        "operation" => "read",
        "thread_id" => "private-invalid-thread-marker"
      })

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        run_server_tools!()
      end)

    refute log =~ "agent.server_tool_poll_failed"
    refute log =~ "private-invalid-thread-marker"

    assert [%{status: :failed, result: %{"reason" => "forbidden"}}] =
             Ledger.read!(Command, id: command.id)

    assert [%{kind: :tool_finished, outcome: :failed}] =
             Ledger.read!(AuditEvent, target_id: command.id)
  end

  test "older executors refuse attachment work with one failure receipt", c do
    {:ok, executor} = ExecutorSession.register(c.binding)

    command =
      internal_command(c, :attachment, %{
        "operation" => "download",
        "attachment_id" => Ecto.UUID.generate(),
        "path" => "/tmp/output"
      })

    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    assert [%{status: :failed, result: %{"reason" => "executor_upgrade_required"}}] =
             Ledger.read!(Command, id: command.id)

    assert [%{kind: :tool_finished, outcome: :failed}] =
             Ledger.read!(AuditEvent, target_id: command.id)

    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)
    assert length(Ledger.read!(AuditEvent, target_id: command.id)) == 1
  end

  test "server worker refuses operations from another tool namespace", c do
    command =
      internal_command(c, :thread, %{
        "operation" => "download",
        "attachment_id" => Ecto.UUID.generate()
      })

    run_server_tools!()

    assert [%{status: :failed, result: %{"reason" => "invalid_operation"}}] =
             Ledger.read!(Command, id: command.id)
  end

  test "capable guest receives version-one context work through the existing fenced lease", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    command = internal_command(c, :context_inventory, %{"version" => 1})
    id = command.id

    assert {:ok, %{id: ^id, status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    assert {:ok, %{status: :started}} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               id,
               :started
             )

    assert {:ok, %{status: :completed}} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               id,
               :completed,
               %{"version" => 1, "entries" => []}
             )
  end

  test "internal command version is checked before claim and again before start", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    command = internal_command(c, :context_read, %{"version" => 2})
    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    assert [%{status: :failed, result: %{"reason" => "invalid_internal_command"}}] =
             Ledger.read!(Command, id: command.id)

    [turn] = Ledger.read!(Turn, id: command.turn_id)
    Ledger.update!(turn, :transition, %{status: :failed, finished_at: Ledger.now()})

    command = internal_command(c, :context_read, %{"version" => 1}, 2)

    assert {:ok, %{status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE agent_commands SET arguments = $2 WHERE id = $1",
      [Ecto.UUID.dump!(command.id), %{"version" => 2}],
      log: false
    )

    assert {:error, :invalid_internal_command} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :started
             )

    assert [%{status: :claimed}] = Ledger.read!(Command, id: command.id)
  end

  test "start rechecks the persisted capability before the guest performs internal work", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    command = internal_command(c, :context_inventory, %{"version" => 1})

    assert {:ok, %{status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE agent_executors SET capabilities = '{}'::text[] WHERE id = $1",
      [Ecto.UUID.dump!(executor.id)],
      log: false
    )

    assert {:error, :executor_upgrade_required} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :started
             )

    assert [%{status: :claimed}] = Ledger.read!(Command, id: command.id)
  end

  @spec internal_command(map(), atom(), map(), pos_integer()) :: Command.t()
  defp internal_command(c, tool, arguments, ordinal \\ 1) do
    turn =
      Ledger.create!(Turn, :enqueue, %{
        thread_id: c.thread.id,
        actor_id: c.actor.id,
        request_key: Ash.UUID.generate(),
        ordinal: ordinal,
        prompt: "prepare context"
      })

    Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
    [thread] = Ledger.read!(Thread, id: c.thread.id)
    Ledger.update!(thread, :advance, %{active_turn_id: turn.id})

    Ledger.create!(Command, :queue, %{
      root_id: c.root.id,
      thread_id: c.thread.id,
      turn_id: turn.id,
      call_id: "internal-#{ordinal}",
      tool: tool,
      arguments: arguments
    })
  end

  # Drives every queued Marshall-owned command through the Oban job that the
  # command transaction enqueued, as the agent_tools queue would.
  @spec run_server_tools!() :: :ok
  defp run_server_tools! do
    Command
    |> Ledger.read!(status: :queued)
    |> Enum.filter(&(&1.tool in Marshall.Agents.ServerTool.tools()))
    |> Enum.each(fn command ->
      :ok = Marshall.Agents.ServerToolJob.perform(%Oban.Job{args: %{"command_id" => command.id}})
    end)
  end
end
