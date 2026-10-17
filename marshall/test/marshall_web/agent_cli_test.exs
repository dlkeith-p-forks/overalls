defmodule MarshallWeb.AgentCLITest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Agents.{AuditEvent, CLIAccess, CLISession, Root, Thread, Turn}
  alias Marshall.Compute.Ledger

  setup do
    host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    secret = "overalls_agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    code = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
    %{owner: owner, vm: vm, thread: thread, secret: secret, code: code}
  end

  test "browser approval binds only the secret digest and exposes a usable CLI RPC", c do
    assert %{"status" => "pending"} = session(c.conn, c.vm.id, c.secret)

    path = "/agents/cli/approve/#{c.vm.id}/#{c.code}"
    {:ok, view, _} = live(signed_in(c.conn, c.owner), path)
    assert has_element?(view, "#agent-cli-approval")
    assert [] = Ledger.read!(CLISession, code_hash: c.code)

    view |> form("#agent-cli-approval") |> render_submit()
    assert_redirect(view)

    assert [%{actor_id: owner_id, vm_id: vm_id}] =
             Ledger.read!(CLISession, code_hash: c.code)

    assert owner_id == c.owner.id
    assert vm_id == c.vm.id

    assert [%{kind: :cli_approved}] =
             Ledger.read!(AuditEvent, actor_id: c.owner.id, kind: :cli_approved)

    assert %{"status" => "approved"} = session(c.conn, c.vm.id, c.secret)

    threads = api(c.conn, :get, "/api/agents/v1/threads?vm_id=#{c.vm.id}", c.secret)
    assert threads.status == 200
    assert %{"threads" => [%{"id" => id}]} = Jason.decode!(threads.resp_body)
    assert id == c.thread.id

    key = Ash.UUID.generate()

    prompt =
      api(c.conn, :post, "/api/agents/v1/prompt", c.secret, %{
        vm_id: c.vm.id,
        thread_id: c.thread.id,
        request_key: key,
        prompt: "inspect"
      })

    assert prompt.status == 200
    %{"turn_id" => turn_id} = Jason.decode!(prompt.resp_body)
    assert [%{prompt: "inspect"}] = Ledger.read!(Turn, id: turn_id)

    turn = api(c.conn, :get, "/api/agents/v1/turn/#{turn_id}?vm_id=#{c.vm.id}", c.secret)
    assert turn.status == 200
    assert Jason.decode!(turn.resp_body)["status"] == "queued"
  end

  test "approval code and other machines cannot act as a CLI bearer", c do
    assert {:ok, _} = CLIAccess.approve(c.vm.id, c.code, c.owner)
    assert %{"error" => "machine_unavailable"} = session(c.conn, c.vm.id, c.code)

    {:ok, other_vm} = Marshall.Compute.provision(request(), actor: c.owner)
    [other_root] = Ledger.read!(Root, vm_id: other_vm.id)
    [other_thread] = Ledger.read!(Thread, root_id: other_root.id)
    wrong = api(c.conn, :get, "/api/agents/v1/threads?vm_id=#{other_vm.id}", c.secret)
    assert wrong.status == 403

    cross_prompt =
      api(c.conn, :post, "/api/agents/v1/prompt", c.secret, %{
        vm_id: c.vm.id,
        thread_id: other_thread.id,
        request_key: Ash.UUID.generate(),
        prompt: "cross"
      })

    assert cross_prompt.status == 403
    assert [] = Ledger.read!(Turn, thread_id: other_thread.id)
    assert {:error, _} = CLIAccess.approve(c.vm.id, c.code, c.owner)
  end

  test "loss of current VM access revokes approved CLI requests", c do
    member = user()

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(member.email),
                 role: :operator,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    assert {:ok, _} = CLIAccess.approve(c.vm.id, c.code, member)
    assert %{"status" => "approved"} = session(c.conn, c.vm.id, c.secret)

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(member.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    assert %{"error" => "machine_unavailable"} = session(c.conn, c.vm.id, c.secret)
    assert api(c.conn, :get, "/api/agents/v1/threads?vm_id=#{c.vm.id}", c.secret).status == 403
  end

  test "a deleted machine makes an approved CLI session explicitly unavailable", c do
    assert {:ok, _} = CLIAccess.approve(c.vm.id, c.code, c.owner)

    assert {:ok, _} =
             Marshall.Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
               actor: c.owner
             )

    assert %{"error" => "machine_unavailable"} = session(c.conn, c.vm.id, c.secret)
    assert api(c.conn, :get, "/api/agents/v1/threads?vm_id=#{c.vm.id}", c.secret).status == 403
  end

  test "expired CLI sessions lose authority and are eventually purged", c do
    assert {:ok, approved} = CLIAccess.approve(c.vm.id, c.code, c.owner)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE agent_cli_sessions SET inserted_at = now() - interval '3 hours', expires_at = now() - interval '2 hours' WHERE id = $1",
      [Ecto.UUID.dump!(approved.id)]
    )

    assert %{"error" => "machine_unavailable"} = session(c.conn, c.vm.id, c.secret)
    assert :ok = CLIAccess.reap()
    assert [] = Ledger.read!(CLISession, id: approved.id)
  end

  test "a second browser approval of the same digest fails cleanly without a crash", c do
    path = "/agents/cli/approve/#{c.vm.id}/#{c.code}"
    {:ok, first, _} = live(signed_in(c.conn, c.owner), path)
    {:ok, second, _} = live(signed_in(build_conn(), c.owner), path)
    assert has_element?(first, "#agent-cli-approval")
    assert has_element?(second, "#agent-cli-approval")

    first |> form("#agent-cli-approval") |> render_submit()
    assert_redirect(first)

    html = second |> form("#agent-cli-approval") |> render_submit()
    assert html =~ "This agent CLI approval is unavailable."

    assert [%{vm_id: vm_id}] = Ledger.read!(CLISession, code_hash: c.code)
    assert vm_id == c.vm.id

    assert [%{kind: :cli_approved, outcome: :accepted}] =
             Ledger.read!(AuditEvent, vm_id: c.vm.id, kind: :cli_approved)

    assert [%{kind: :cli_refused, outcome: :failed, actor_id: actor_id}] =
             Ledger.read!(AuditEvent, vm_id: c.vm.id, kind: :cli_refused)

    assert actor_id == c.owner.id
    assert Process.alive?(second.pid)
  end

  test "unauthorized CLI API requests emit the catalogued denial event", c do
    alias Plug.Conn

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        no_bearer =
          c.conn
          |> recycle()
          |> Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            @endpoint,
            :get,
            "https://www.example.com/api/agents/v1/threads?vm_id=#{c.vm.id}",
            ""
          )

        assert no_bearer.status == 403

        wrong_vm =
          c.conn
          |> recycle()
          |> Conn.put_req_header("authorization", "Bearer " <> c.secret)
          |> Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            @endpoint,
            :get,
            "https://www.example.com/api/agents/v1/threads?vm_id=#{Ash.UUID.generate()}",
            ""
          )

        assert wrong_vm.status == 403
      end)

    assert log =~ "event=api.request_unauthorized"
    refute log =~ c.secret
  end

  defp session(conn, vm_id, token) do
    conn
    |> api(:get, "/api/agents/v1/session?vm_id=#{vm_id}", token)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp api(conn, method, path, token, body \\ nil) do
    payload = if body, do: Jason.encode!(body), else: ""

    conn
    |> recycle()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(
      &Phoenix.ConnTest.dispatch(
        &1,
        @endpoint,
        method,
        "https://www.example.com" <> path,
        payload
      )
    )
  end

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
