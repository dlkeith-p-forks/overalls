defmodule MarshallWeb.AgentCLIHistoryTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User
  alias Marshall.Agents.{CLISession, Root, Thread, Turn}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.ComputeFixtures, as: Fixtures

  @moduletag capture_log: true
  @type role :: :web | :viewer | :operator | :manager | :revoked
  @type operation :: {:direct, role()} | {:team, :member | :admin | :removed}
  @type model :: %{direct: role(), team: boolean()}
  @type fixture :: %{
          owner: User.t(),
          member: User.t(),
          vm: VirtualMachine.t(),
          other: VirtualMachine.t(),
          thread: Thread.t(),
          other_thread: Thread.t(),
          team_id: String.t(),
          conn: Plug.Conn.t()
        }
  @type credential :: %{secret: String.t(), code: String.t()}
  @type inventory :: %{String.t() => [[String.t()]]}

  # @cc [owner:ghuntley,label:verification;security] cli-independent-sharing-histories
  # Expected CLI write authority MUST come from the independent role model after
  # public direct/team actions. Every step checks both an existing approved secret
  # and a fresh explicit browser approval; refusal MUST preserve complete scoped
  # persisted rows, including prior turns, sessions, audit and wake operations.
  property "CLI invocations follow direct and team authority histories", test_cases: 8 do
    check all(
            tail <-
              list_of(
                one_of([
                  map(member_of([:web, :viewer, :operator, :manager, :revoked]), &{:direct, &1}),
                  map(member_of([:member, :admin, :removed]), &{:team, &1})
                ]),
                max_length: 5
              ),
            test_cases: 8
          ) do
      c = fixture()
      model = change(c, %{direct: :revoked, team: false}, {:direct, :operator})
      existing = credential()
      approve(c, existing, true)
      prompt(c, existing, true)
      [original_turn] = Ledger.read!(Turn, thread_id: c.thread.id)

      operations =
        [
          {:direct, :viewer},
          {:direct, :web},
          {:team, :member},
          {:direct, :revoked},
          {:team, :removed},
          {:team, :admin},
          {:team, :removed},
          {:direct, :manager}
        ] ++ tail

      Enum.reduce(operations, model, fn operation, model ->
        model = change(c, model, operation)
        permitted = model.team or model.direct in [:operator, :manager]
        before = inventory(c)

        for path <- [
              "/api/agents/v1/session?vm_id=#{c.vm.id}",
              "/api/agents/v1/threads?vm_id=#{c.vm.id}",
              "/api/agents/v1/turn/#{original_turn.id}?vm_id=#{c.vm.id}"
            ] do
          response = api(c.conn, :get, path, existing.secret)
          assert response.status == if(permitted, do: 200, else: 403)
          assert inventory(c) == before
        end

        prompt(c, existing, permitted)
        fresh = credential()
        assert fresh.code != existing.code
        approve(c, fresh, permitted)
        prompt(c, fresh, permitted)
        model
      end)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] cli-exact-binding-and-idempotency
  # Digest URLs MUST NOT authenticate API calls. Wrong VM/thread and changed
  # replay payloads MUST preserve prior state; exact request replay MUST retain
  # one turn and its original audit/wake inventory across fresh invocations.
  property "approved secrets retain exact machine, thread and request bindings", test_cases: 8 do
    check all(
            repeats <- integer(2..5),
            payload <- member_of(["inspect", "read", "check"]),
            test_cases: 8
          ) do
      c = fixture()
      change(c, %{direct: :revoked, team: false}, {:direct, :operator})
      token = credential()
      approve(c, token, true)
      key = Ash.UUID.generate()
      body = %{vm_id: c.vm.id, thread_id: c.thread.id, request_key: key, prompt: payload}
      accepted = api(c.conn, :post, "/api/agents/v1/prompt", token.secret, body)
      assert accepted.status == 200
      before = inventory(c)

      for _ <- 1..repeats do
        retry = api(c.conn, :post, "/api/agents/v1/prompt", token.secret, body)
        assert retry.status == 200
        assert retry.resp_body == accepted.resp_body
        assert inventory(c) == before
      end

      for {secret, denied_body} <- [
            {token.code, body},
            {credential().secret, body},
            {token.secret, %{body | vm_id: c.other.id, thread_id: c.other_thread.id}},
            {token.secret, %{body | thread_id: c.other_thread.id}},
            {token.secret, %{body | prompt: payload <> " changed"}}
          ] do
        assert api(c.conn, :post, "/api/agents/v1/prompt", secret, denied_body).status == 403
        assert inventory(c) == before
      end

      fresh = credential()
      approve(c, fresh, true)
      after_approval = inventory(c)
      retry = api(c.conn, :post, "/api/agents/v1/prompt", fresh.secret, body)
      assert retry.status == 200 and retry.resp_body == accepted.resp_body
      assert inventory(c) == after_approval
    end
  end

  # @cc [owner:ghuntley,label:verification;security] cli-browser-and-session-lifetimes
  # Signing out the approving browser MUST refuse that browser's stale approval,
  # while its already-approved one-hour CLI authority remains independently live.
  # Synthetic expiry, real retirement and VM deletion MUST all run in every
  # generated order and refuse every subsequent mutation. Generation and
  # shrinking MUST preserve all three boundaries without rejection exhaustion.
  property "browser sign-out and CLI expiry have separate authority boundaries", test_cases: 4 do
    check all(
            boundaries <- shuffle([:expiry, :delete, :retire]),
            expiry_age <- integer(1..3600),
            test_cases: 4
          ) do
      Enum.each(boundaries, &lifetime_boundary(&1, expiry_age))
    end
  end

  @spec lifetime_boundary(:expiry | :delete | :retire, pos_integer()) :: :ok
  defp lifetime_boundary(boundary, expiry_age) do
    c = fixture()
    change(c, %{direct: :revoked, team: false}, {:direct, :operator})
    token = credential()
    approve(c, token, true)
    pending = credential()
    {:ok, view, _} = live(c.conn, approval_path(c, pending))
    assert has_element?(view, "#agent-cli-approval")
    before = inventory(c)
    signed_out = delete(c.conn, "/sign-out")
    assert signed_out.status == 302
    view |> form("#agent-cli-approval") |> render_submit()
    assert inventory(c) == before
    prompt(c, token, true)

    case boundary do
      :expiry ->
        [session] = Ledger.read!(CLISession, code_hash: token.code)

        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "UPDATE agent_cli_sessions SET inserted_at = now() - ($2::integer + 3600) * interval '1 second', expires_at = now() - $2::integer * interval '1 second' WHERE id = $1",
          [Ecto.UUID.dump!(session.id), expiry_age]
        )

      :delete ->
        assert {:ok, _} =
                 Marshall.Compute.lifecycle(
                   %{vm_id: c.vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
                   actor: c.owner
                 )

      :retire ->
        admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))

        assert {:ok, %{deleting: true}} =
                 User
                 |> Ash.ActionInput.for_action(
                   :delete_user,
                   %{user_id: c.member.id, confirmation: to_string(c.member.email)},
                   actor: admin
                 )
                 |> Ash.run_action()
    end

    prompt(c, token, false)
    before = inventory(c)

    assert api(c.conn, :get, "/api/agents/v1/threads?vm_id=#{c.vm.id}", token.secret).status ==
             403

    assert inventory(c) == before
    :ok
  end

  @spec fixture() :: fixture()
  defp fixture do
    Fixtures.host_fixture()
    owner = Fixtures.user()
    member = Fixtures.user()

    {:ok, team} =
      Marshall.Teams.create_team(
        %{name: "cli-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    {:ok, vm} =
      Marshall.Compute.provision(Fixtures.request(%{team_id: team.id, profile: :oss, vcpu: 1}),
        actor: owner
      )

    {:ok, other} = Marshall.Compute.provision(Fixtures.request(%{vcpu: 1}), actor: owner)
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    [other_root] = Ledger.read!(Root, vm_id: other.id)
    [other_thread] = Ledger.read!(Thread, root_id: other_root.id)
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(member)
    actor = Ash.Resource.put_metadata(member, :token, token)

    conn =
      build_conn()
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(actor)

    %{
      owner: owner,
      member: member,
      vm: vm,
      other: other,
      thread: thread,
      other_thread: other_thread,
      team_id: team.id,
      conn: conn
    }
  end

  @spec credential() :: credential()
  defp credential do
    secret = "overalls_agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    %{secret: secret, code: Base.encode16(:crypto.hash(:sha256, secret), case: :lower)}
  end

  @spec change(fixture(), model(), operation()) :: model()
  defp change(c, model, {:direct, role}) do
    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(c.member.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    %{model | direct: role}
  end

  defp change(c, model, {:team, role}) do
    assert {:ok, _} =
             Marshall.Teams.set_team_member(
               %{
                 team_id: c.team_id,
                 email: to_string(c.member.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    %{model | team: role != :removed}
  end

  @spec approval_path(fixture(), credential()) :: String.t()
  defp approval_path(c, token), do: "/agents/cli/approve/#{c.vm.id}/#{token.code}"

  @spec approve(fixture(), credential(), boolean()) :: :ok
  defp approve(c, token, permitted) do
    before = inventory(c)
    {:ok, view, _} = live(c.conn, approval_path(c, token))
    assert inventory(c) == before
    assert has_element?(view, "#agent-cli-approval") == permitted

    if permitted do
      view |> form("#agent-cli-approval") |> render_submit()
      assert_redirect(view)
      assert [%{actor_id: actor, vm_id: vm}] = Ledger.read!(CLISession, code_hash: token.code)
      assert actor == c.member.id and vm == c.vm.id
    else
      render_hook(view, "approve", %{})
      assert inventory(c) == before
    end

    :ok
  end

  @spec prompt(fixture(), credential(), boolean()) :: :ok
  defp prompt(c, token, permitted) do
    before = inventory(c)

    response =
      api(c.conn, :post, "/api/agents/v1/prompt", token.secret, %{
        vm_id: c.vm.id,
        thread_id: c.thread.id,
        request_key: Ash.UUID.generate(),
        prompt: "inspect"
      })

    assert response.status == if(permitted, do: 200, else: 403)
    unless permitted, do: assert(inventory(c) == before)
    :ok
  end

  @spec inventory(fixture()) :: inventory()
  defp inventory(c) do
    for {table, predicate} <- [
          {"agent_cli_sessions", "vm_id = $1 OR vm_id = $2"},
          {"agent_audit_events", "vm_id = $1 OR vm_id = $2"},
          {"compute_operations", "vm_id = $1 OR vm_id = $2"},
          {"compute_virtual_machines", "id = $1 OR id = $2"},
          {"agent_turns",
           "thread_id IN (SELECT t.id FROM agent_threads t JOIN agent_roots r ON r.id=t.root_id WHERE r.vm_id=$1 OR r.vm_id=$2)"},
          {"agent_threads", "root_id IN (SELECT id FROM agent_roots WHERE vm_id=$1 OR vm_id=$2)"}
        ],
        into: %{} do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT id::text, md5(row_to_json(t)::text) FROM #{table} t WHERE #{predicate} ORDER BY id",
          [Ecto.UUID.dump!(c.vm.id), Ecto.UUID.dump!(c.other.id)]
        )

      {table, rows}
    end
  end

  @spec api(Plug.Conn.t(), atom(), String.t(), String.t(), map() | nil) :: Plug.Conn.t()
  defp api(conn, method, path, secret, body \\ nil) do
    conn
    |> recycle()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(
      &Phoenix.ConnTest.dispatch(
        &1,
        @endpoint,
        method,
        "https://www.example.com" <> path,
        if(body, do: Jason.encode!(body), else: "")
      )
    )
  end
end
