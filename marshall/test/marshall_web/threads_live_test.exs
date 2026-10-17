defmodule MarshallWeb.ThreadsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures

  setup do
    host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    %{owner: owner, vm: vm}
  end

  test "thread index links to new and activity views", c do
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads")
    assert has_element?(view, "#threads")
    assert has_element?(view, "a[href='/threads/new']", "New thread")
    assert has_element?(view, "a[href='/threads/activity']", "Activity")
  end

  test "new thread view collects an objective and machine settings", c do
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/new")
    assert has_element?(view, "#new-thread-form")
    assert has_element?(view, "textarea[name='thread[objective]']")
    assert has_element?(view, "select[name='thread[mode]']")
    assert has_element?(view, "#create-thread")
  end

  # @cc [owner:ghuntley,label:verification;product] composer-mode-does-not-provision
  # Choosing a collaboration mode or inspecting help on a new thread MUST keep
  # the form on that route without creating a task, machine or agent turn.
  test "new-thread commands choose collaboration without provisioning", c do
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/new")

    before_threads =
      Marshall.Compute.Ledger.read!(Marshall.Threads.Thread, creator_id: c.owner.id)

    before_machines =
      Marshall.Compute.Ledger.read!(Marshall.Compute.VirtualMachine, owner_id: c.owner.id)

    assert has_element?(view, "#thread-command-palette")
    assert has_element?(view, "[data-thread-commands-open]", "Commands")

    assert has_element?(
             view,
             "select[name='thread[collaboration_mode]'] option[value='work'][selected]"
           )

    view |> form("#new-thread-form", thread: %{objective: "/plan"}) |> render_submit()

    assert has_element?(
             view,
             "select[name='thread[collaboration_mode]'] option[value='plan'][selected]"
           )

    assert has_element?(view, "select[name='thread[mode]'] option[value='medium'][selected]")

    render_click(view, "thread_command", %{"command" => "help"})
    assert has_element?(view, "#thread-detail-dialog", "Composer help")
    render_click(view, "close_thread_dialog")
    refute has_element?(view, "#thread-detail-dialog")

    assert Marshall.Compute.Ledger.read!(Marshall.Threads.Thread, creator_id: c.owner.id) ==
             before_threads

    assert Marshall.Compute.Ledger.read!(Marshall.Compute.VirtualMachine, owner_id: c.owner.id) ==
             before_machines
  end

  test "unknown commands preserve the draft without admitting a thread", c do
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/new")

    view
    |> form("#new-thread-form", thread: %{objective: "/unknown keep this draft"})
    |> render_submit()

    assert has_element?(view, "#thread-form-error", "Unknown command")
    assert has_element?(view, "textarea[name='thread[objective]']", "/unknown keep this draft")
    assert Marshall.Compute.Ledger.read!(Marshall.Threads.Thread, creator_id: c.owner.id) == []
  end

  # @cc [owner:ghuntley,label:verification;security] thread-index-filter-authorized-results
  # Search and lifecycle filters MUST narrow the current user's authorized
  # thread list, preserve their selection through refresh, and restore the
  # authorized list when cleared without revealing another creator's thread.
  test "index search and status filters retain only authorized matching threads", c do
    alias Marshall.Compute.Ledger

    active = create_thread(c.owner, "Investigate deployment latency")
    archived = create_thread(c.owner, "Retain the previous release")
    Ledger.update!(archived, :set_title, %{title: "Deployment notes"})

    Ledger.update!(archived, :mark_archived, %{status: :archived, archived_at: DateTime.utc_now()})

    private = create_thread(user(), "Deployment details for another owner")

    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads")

    assert has_element?(view, "#thread-list-items a[href='/threads/#{active.id}']")
    assert has_element?(view, "#thread-list-items a[href='/threads/#{archived.id}']")
    refute has_element?(view, "#thread-list-items a[href='/threads/#{private.id}']")

    view
    |> form("#thread-index-filter", filter: %{query: "  DEPLOYMENT  ", status: "active"})
    |> render_change()

    assert has_element?(view, "#thread-list-items a[href='/threads/#{active.id}']")
    refute has_element?(view, "#thread-list-items a[href='/threads/#{archived.id}']")
    refute has_element?(view, "#thread-list-items a[href='/threads/#{private.id}']")

    send(view.pid, :refresh_threads)
    assert has_element?(view, "#thread-list-items a[href='/threads/#{active.id}']")
    refute has_element?(view, "#thread-list-items a[href='/threads/#{archived.id}']")

    view
    |> form("#thread-index-filter", filter: %{query: "deployment", status: "archived"})
    |> render_change()

    assert has_element?(view, "#thread-list-items a[href='/threads/#{archived.id}']")
    refute has_element?(view, "#thread-list-items a[href='/threads/#{active.id}']")
    refute has_element?(view, "#thread-list-items a[href='/threads/#{private.id}']")

    view
    |> form("#thread-index-filter", filter: %{query: "unmatched objective", status: "all"})
    |> render_change()

    assert has_element?(view, "#thread-search-empty")
    refute has_element?(view, "#thread-list-items a")

    view
    |> form("#thread-index-filter", filter: %{query: "", status: "all"})
    |> render_change()

    assert has_element?(view, "#thread-list-items a[href='/threads/#{active.id}']")
    assert has_element?(view, "#thread-list-items a[href='/threads/#{archived.id}']")
    refute has_element?(view, "#thread-list-items a[href='/threads/#{private.id}']")
    refute has_element?(view, "#thread-search-empty")
  end

  test "activity filters narrow authorized status and sharing scope", c do
    own = create_thread(c.owner, "My activity")
    shared = create_thread(c.owner, "Shared activity")
    collaborator = user()
    :ok = set_thread_access(c.owner, shared, collaborator, :viewer)

    {:ok, view, _html} = live(signed_in(c.conn, collaborator), ~p"/threads/activity")

    assert has_element?(view, "#thread-activity-items a[href='/threads/#{shared.id}']")
    refute has_element?(view, "#thread-activity-items a[href='/threads/#{own.id}']")

    view
    |> form("#thread-activity-filter",
      filter: %{status: "all", time: "all", owner: "mine"}
    )
    |> render_change()

    refute has_element?(view, "#thread-activity-items a[href='/threads/#{shared.id}']")

    view
    |> form("#thread-activity-filter",
      filter: %{status: "all", time: "all", owner: "shared"}
    )
    |> render_change()

    assert has_element?(view, "#thread-activity-items a[href='/threads/#{shared.id}']")
    refute has_element?(view, "#thread-activity-items a[href='/threads/#{own.id}']")
    assert has_element?(view, "#thread-activity-time-filter")
    assert has_element?(view, "#thread-activity-owner-filter")
  end

  # @cc [owner:ghuntley,label:verification;security] pending-thread-preserves-objective
  # A pending thread MUST display its authorized saved objective and explain
  # provisioning without prompt or terminal controls. Prompt admission MUST
  # remain refused until the thread is ready.
  test "pending thread retains the objective while work controls remain unavailable", c do
    thread = create_thread(c.owner, "Prepare the next release")
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/#{thread.id}")

    assert has_element?(view, "#thread-provisioning")
    assert has_element?(view, "#thread-events", "Prepare the next release")
    refute has_element?(view, "#thread-prompt-form")
    refute has_element?(view, "#thread-terminal")
    refute has_element?(view, "#thread-vscode")

    render_submit(view, "prompt", %{"prompt" => %{"text" => "Do not admit before ready"}})
    assert has_element?(view, "#thread-operation-error", "This thread is still provisioning.")
    assert Marshall.Compute.Ledger.read!(Marshall.Agents.Turn, actor_id: c.owner.id) == []
  end

  # @cc [owner:ghuntley,label:verification;product] thread-conversation-reading-order
  # The reply composer MUST precede the transcript in document order. Events
  # MUST appear newest first by their persisted sequence, including after refresh.
  test "the reply composer precedes newest-first events across refresh", c do
    alias Marshall.Compute.Ledger

    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: c.vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)
    thread = create_thread(c.owner, "Follow the deployment", c.vm.idempotency_key)

    Ledger.update!(thread, :bind_machine, %{
      machine_id: c.vm.id,
      agent_root_id: root.id,
      agent_thread_id: agent_thread.id,
      status: :ready
    })

    current_thread = Ledger.read!(Marshall.Threads.Thread, id: thread.id) |> hd()

    Ledger.create!(Marshall.Threads.Generation, :open, %{
      thread_id: current_thread.id,
      ordinal: 2,
      machine_key: "retired:" <> Ash.UUID.generate(),
      status: :archived,
      archived_at: DateTime.utc_now()
    })

    older =
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: agent_thread.id,
        sequence: agent_thread.next_event_sequence,
        kind: :assistant,
        body: %{"text" => "The earlier update"}
      })

    newer =
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: agent_thread.id,
        sequence: agent_thread.next_event_sequence + 1,
        kind: :assistant,
        body: %{"text" => "The later update"}
      })

    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/#{thread.id}")

    assert has_element?(view, "#thread-generations")
    assert has_element?(view, "#thread-generation-selector option[value='1']")
    assert has_element?(view, "#thread-generation-selector option[value='2']")

    assert conversation_order(view) == [
             "thread-prompt-form",
             "events-#{newer.id}",
             "events-#{older.id}"
           ]

    latest =
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: agent_thread.id,
        sequence: agent_thread.next_event_sequence + 2,
        kind: :assistant,
        body: %{"text" => "The newest update"}
      })

    send(view.pid, :refresh_threads)

    assert conversation_order(view) == [
             "thread-prompt-form",
             "events-#{latest.id}",
             "events-#{newer.id}",
             "events-#{older.id}"
           ]
  end

  # @cc [owner:ghuntley,label:verification;security] thread-editor-current-capability
  # A ready thread MUST offer the editor only while its bound machine's current
  # projection permits it. A mounted thread MUST remove the link on refresh when
  # a stop is requested, even if the thread itself remains ready.
  test "editor access follows the bound machine's current eligibility", c do
    alias Marshall.Compute.Ledger
    alias Marshall.EditorFixture

    previous = Application.fetch_env(:marshall, :ingress_editor_release)
    Application.put_env(:marshall, :ingress_editor_release, EditorFixture.descriptor())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :ingress_editor_release, value)
        :error -> Application.delete_env(:marshall, :ingress_editor_release)
      end
    end)

    fixture = EditorFixture.new()
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: fixture.vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)

    thread =
      create_thread(
        fixture.owner,
        "Review the implementation in the editor",
        fixture.vm.idempotency_key
      )

    Ledger.update!(thread, :bind_machine, %{
      machine_id: fixture.vm.id,
      agent_root_id: root.id,
      agent_thread_id: agent_thread.id,
      status: :ready
    })

    {:ok, view, _html} = live(signed_in(c.conn, fixture.owner), ~p"/threads/#{thread.id}")
    assert has_element?(view, "#thread-vscode[href='/machines/#{fixture.vm.id}/code']")

    assert has_element?(
             view,
             "#thread-terminal-embed iframe[data-thread-terminal-src='/machines/#{fixture.vm.id}/terminals']"
           )

    Ledger.intent!(fixture.vm, %{
      desired_state: :stopped,
      generation: fixture.vm.generation + 1
    })

    send(view.pid, :refresh_threads)
    refute has_element?(view, "#thread-vscode")
    assert has_element?(view, "#thread-prompt-form")
  end

  # @cc [owner:ghuntley,label:verification;security] thread-live-current-shared-authority
  # A shared thread MUST render controls for the current grant role, and refresh
  # MUST remove transcript and mutation controls after that grant is revoked.
  # A viewer's forged prompt and sharing events MUST NOT admit an agent turn or
  # elevate that viewer's role.
  test "shared controls follow role changes and revocation on refresh", c do
    alias Marshall.Compute.Ledger

    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: c.vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)
    thread = create_thread(c.owner, "A shared release investigation", c.vm.idempotency_key)

    Ledger.update!(thread, :bind_machine, %{
      machine_id: c.vm.id,
      agent_root_id: root.id,
      agent_thread_id: agent_thread.id,
      status: :ready
    })

    collaborator = user()
    :ok = set_thread_access(c.owner, thread, collaborator, :viewer)
    {:ok, view, _html} = live(signed_in(c.conn, collaborator), ~p"/threads/#{thread.id}")

    assert has_element?(view, "#thread-events", "A shared release investigation")
    assert has_element?(view, "#thread-read-only")
    refute has_element?(view, "#thread-prompt-form")
    refute has_element?(view, "#thread-terminal")
    refute has_element?(view, "#thread-vscode")
    refute has_element?(view, "#thread-share-toggle")
    refute has_element?(view, "button[phx-click='archive']")

    render_submit(view, "prompt", %{"prompt" => %{"text" => "A viewer cannot submit this"}})
    assert has_element?(view, "#thread-operation-error")
    assert Ledger.read!(Marshall.Agents.Turn, actor_id: collaborator.id) == []

    render_submit(view, "thread_share", %{
      "access" => %{"email" => to_string(collaborator.email), "role" => "manager"}
    })

    assert has_element?(view, "#thread-read-only")
    refute has_element?(view, "#thread-share-toggle")

    :ok = set_thread_access(c.owner, thread, collaborator, :operator)
    send(view.pid, :refresh_threads)
    assert has_element?(view, "#thread-prompt-form")
    assert has_element?(view, "#thread-terminal")
    refute has_element?(view, "#thread-read-only")
    refute has_element?(view, "#thread-share-toggle")
    refute has_element?(view, "button[phx-click='archive']")

    :ok = set_thread_access(c.owner, thread, collaborator, :manager)
    send(view.pid, :refresh_threads)
    assert has_element?(view, "#thread-prompt-form")
    assert has_element?(view, "#thread-share-toggle")
    assert has_element?(view, "button[phx-click='archive']")

    :ok = set_thread_access(c.owner, thread, collaborator, :revoked)
    send(view.pid, :refresh_threads)
    assert has_element?(view, "#thread-forbidden")
    refute has_element?(view, "#thread-events")
    refute has_element?(view, "#thread-prompt-form")
    refute has_element?(view, "#thread-terminal")
    refute has_element?(view, "#thread-vscode")
    refute has_element?(view, "#thread-share-toggle")
  end

  test "the sharing form grants access to a registered user", c do
    thread = create_thread(c.owner, "Share before the machine is ready")
    collaborator = user()
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/#{thread.id}")

    view |> element("#thread-share-toggle") |> render_click()

    view
    |> form("#thread-access-form",
      access: %{email: to_string(collaborator.email), role: "viewer"}
    )
    |> render_submit()

    assert has_element?(view, "#thread-grant-items", to_string(collaborator.email))

    assert {:ok, visible} =
             Marshall.Threads.get_thread(%{thread_id: thread.id}, actor: collaborator)

    assert visible.id == thread.id
  end

  test "a thread is hidden from a user who is not its creator", c do
    assert {:ok, thread} =
             Marshall.Threads.create_thread(
               %{
                 objective: "Private deployment objective",
                 mode: :medium,
                 machine_spec: Marshall.ComputeFixtures.request(),
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    outsider = Marshall.ComputeFixtures.user()
    {:ok, view, _html} = live(signed_in(c.conn, outsider), ~p"/threads/#{thread.id}")

    assert has_element?(view, "#thread-forbidden", "You do not have access to this thread.")
    refute has_element?(view, "#thread-events", "Private deployment objective")
  end

  test "failed provisioning exposes retry controls", c do
    assert {:ok, thread} =
             Marshall.Threads.create_thread(
               %{
                 objective: "Retry this deployment",
                 mode: :medium,
                 machine_spec: Marshall.ComputeFixtures.request(),
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    failed =
      Marshall.Compute.Ledger.update!(thread, :mark_failed, %{
        status: :failed,
        failure_reason: :capacity
      })

    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/#{failed.id}")
    assert has_element?(view, "#thread-provision-error", "Provisioning needs attention.")
    assert has_element?(view, "button", "Retry")

    view
    |> element("#thread-workspace button", "Retry")
    |> render_click()

    assert render(view) =~ "Provisioning will retry."
  end

  test "missing thread displays an explicit not found state and refuses mutation events", c do
    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/#{Ash.UUID.generate()}")

    assert has_element?(view, "#thread-not-found")

    for event <- ["retry", "archive", "delete", "reopen"] do
      render_click(view, event, %{})
      assert has_element?(view, "#thread-not-found")
    end

    render_submit(view, "prompt", %{"prompt" => %{"text" => "Do not enqueue this"}})
    assert has_element?(view, "#thread-not-found")
    assert Marshall.Compute.Ledger.read!(Marshall.Agents.Turn, actor_id: c.owner.id) == []
  end

  test "archived thread retains its transcript and only offers reopen", c do
    alias Marshall.Compute.Ledger
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: c.vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)

    assert {:ok, thread} =
             Marshall.Threads.create_thread(
               %{
                 objective: "Retain the completed task",
                 machine_spec: request(),
                 idempotency_key: c.vm.idempotency_key
               },
               actor: c.owner
             )

    bound =
      Ledger.update!(thread, :bind_machine, %{
        machine_id: c.vm.id,
        agent_root_id: root.id,
        agent_thread_id: agent_thread.id,
        status: :ready
      })

    Ledger.create!(Marshall.Agents.Event, :append, %{
      thread_id: agent_thread.id,
      sequence: agent_thread.next_event_sequence,
      kind: :assistant,
      body: %{"text" => "The completed task is retained."}
    })

    :ok = Ledger.archive!(c.vm, :archive)
    Ledger.update!(bound, :mark_archived, %{status: :archived, archived_at: DateTime.utc_now()})

    {:ok, view, _html} = live(signed_in(c.conn, c.owner), ~p"/threads/#{thread.id}")
    assert has_element?(view, "#thread-archived", "read-only")
    assert has_element?(view, "#thread-events", "The completed task is retained.")
    assert has_element?(view, "button[phx-click='reopen']", "Reopen")
    refute has_element?(view, "#thread-prompt-form")
    refute has_element?(view, "#thread-terminal")
    refute has_element?(view, "#thread-vscode")
    refute has_element?(view, "button[phx-click='archive']")
    refute has_element?(view, "button[phx-click='delete']")
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @spec conversation_order(Phoenix.LiveViewTest.View.t()) :: [String.t()]
  defp conversation_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#thread-prompt-form, #thread-transcript > article")
    |> LazyHTML.attribute("id")
  end

  @spec create_thread(Marshall.Accounts.User.t(), String.t()) :: Marshall.Threads.Thread.t()
  @spec create_thread(Marshall.Accounts.User.t(), String.t(), String.t()) ::
          Marshall.Threads.Thread.t()
  defp create_thread(owner, objective, idempotency_key \\ Ash.UUID.generate()) do
    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: objective,
          machine_spec: request(),
          idempotency_key: idempotency_key
        },
        actor: owner
      )

    thread
  end

  @spec set_thread_access(
          Marshall.Accounts.User.t(),
          Marshall.Threads.Thread.t(),
          Marshall.Accounts.User.t(),
          :viewer | :operator | :manager | :revoked
        ) :: :ok
  defp set_thread_access(owner, thread, recipient, role) do
    {:ok, _grant} =
      Marshall.Threads.set_access(
        %{
          thread_id: thread.id,
          email: to_string(recipient.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    :ok
  end
end
