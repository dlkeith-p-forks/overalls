defmodule MarshallWeb.ControlRoomAccessTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger

  @pages ~w(users nodes jobs access workloads operations usage audit git)

  test "promotion in an open view refreshes the actor and retains mutation auditing", %{
    conn: conn
  } do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    reader = Marshall.PasskeyFixture.verified_session(fixture.owner)
    {:ok, view, _} = live(signed_in(conn, reader), ~p"/admin/workloads")
    refute has_element?(view, "#stop-#{fixture.vm.id}")
    Ledger.update!(reader, :assign_administrator, %{administrator: true})
    render_click(view, "lifecycle", %{"id" => fixture.vm.id, "kind" => "stop"})
    assert render(view) =~ "Lifecycle request queued"

    assert [%{kind: :vm_lifecycle, actor_id: actor_id}] =
             Ledger.read!(Marshall.Accounts.AdminEvent)

    assert actor_id == reader.id
  end

  test "enrolled readers can open Control room data and export usage without elevation", %{
    conn: conn
  } do
    {reader, token} = Marshall.PasskeyFixture.login(Marshall.PasskeyFixture.user())
    Marshall.PasskeyFixture.register(reader)
    conn = signed_in(conn, Ash.Resource.put_metadata(reader, :token, token))
    {:ok, users, _} = live(conn, ~p"/admin/users")
    assert has_element?(users, "#admin-user-rows")
    {:ok, machines, _} = live(conn, ~p"/machines")
    assert has_element?(machines, "#main-content")
    assert get(conn, ~p"/admin/usage/export").status == 200
  end

  test "ordinary users can inspect a failed job but cannot retry it", %{conn: conn} do
    job =
      %{}
      |> Oban.Job.new(worker: "Marshall.TestWorker")
      |> Oban.insert!()
      |> Ecto.Changeset.change(state: "discarded", attempt: 1)
      |> Marshall.Repo.update!()

    reader = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.verified_session()
    {:ok, view, _} = live(signed_in(conn, reader), ~p"/admin/jobs/#{job.id}")
    assert has_element?(view, "#job-detail", "Failed")
    refute has_element?(view, "#retry-job")
    assert render_click(view, "retry", %{}) =~ "Administrative changes require an administrator"

    assert {:error, _} =
             Marshall.Administration.retry_job(%{id: job.id, request_id: Ash.UUID.generate()},
               actor: reader
             )

    assert Marshall.Repo.get!(Oban.Job, job.id).state == "discarded"
    assert Ledger.read!(Marshall.Administration.AuditEvent) == []
  end

  test "anonymous visitors cannot browse the Control room or export usage", %{conn: conn} do
    for page <- @pages do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin/" <> page)
    end

    assert get(conn, ~p"/admin/usage/export").status == 404
  end

  test "ordinary readers see populated inventories and retain read interactions", %{conn: conn} do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    reader = Marshall.ComputeFixtures.user()
    conn = signed_in(conn, reader)

    repo =
      Ledger.create!(Marshall.Enrico.Repository, :register, %{
        namespace: "github",
        owner: "readers",
        name: "example",
        registered_by_id: fixture.owner.id
      })

    Ledger.create!(Marshall.Enrico.AuditEvent, :record, %{
      repository_id: repo.id,
      actor_id: fixture.owner.id,
      kind: :registered
    })

    Ledger.create!(Marshall.Accounts.AdminEvent, :record, %{
      actor_id: fixture.owner.id,
      target_id: repo.id,
      kind: :host_configure
    })

    job =
      Oban.insert!(
        Oban.Job.new(%{"credential" => "private-job-payload"}, worker: "Marshall.TestWorker")
      )

    public_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 91::256>>)
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public_key}, actor: fixture.owner)
    {gateway_token, _} = Marshall.SSH.Token.issue(:gateway)

    {:ok, _} =
      Marshall.SSH.configure_gateway(%{name: "read-only", token: gateway_token},
        actor: SystemActor.compute()
      )

    {:ok, ssh} =
      Marshall.SSH.open_session(%{gateway_token: gateway_token, public_key: public_key},
        actor: SystemActor.compute()
      )

    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, reader, :viewer)

    {:ok, credential} = Marshall.Inference.Credentials.rotate(fixture.vm.host_id, 3600)

    usage =
      Ledger.create!(Marshall.Inference.Request, :record, %{
        host_id: fixture.vm.host_id,
        vm_id: fixture.vm.id,
        placement_id: fixture.vm.current_placement_id,
        execution_epoch: fixture.vm.execution_epoch,
        generation: fixture.vm.generation,
        owner_id: fixture.owner.id,
        credential_id: credential.id,
        provider: :openai,
        model: "read-only-model",
        operation: :responses,
        expires_at: DateTime.add(Ledger.now(), 30)
      })

    for {page, selector, text} <- [
          {"users", "#admin-user-rows", to_string(fixture.owner.email)},
          {"nodes", "#lilly-node-rows", fixture.host.name},
          {"jobs", "#jobs-#{job.id}", "Queued"},
          {"access", "#admin-key-#{key.id}", key.fingerprint},
          {"workloads", "#admin-workload-#{fixture.vm.id}", fixture.vm.name},
          {"operations", "h2", "Image catalog"},
          {"usage", "#main-content", "read-only-model"},
          {"audit", "#audit-events", repo.id},
          {"git", "#main-content", "readers/example"}
        ] do
      {:ok, view, html} = live(conn, "/admin/" <> page)
      assert has_element?(view, selector, text)
      assert has_element?(view, "a[href='/admin/nodes']", "Control room")

      refute has_element?(
               view,
               "[phx-click='revoke-key'], [phx-click='lifecycle'], [phx-submit='invite'], [phx-submit='register']"
             )

      for secret <- [public_key, gateway_token, ssh.session_token, "private-job-payload"],
          do: refute(html =~ secret)
    end

    {:ok, node, _} = live(conn, ~p"/admin/nodes/#{fixture.host.id}")
    node |> element("#capacity-details") |> render_click()
    assert has_element?(node, "#admission-overhead")
    refute has_element?(node, "#admission-settings")
    refute has_element?(node, "#start-evacuation")
    node |> element("#preview-evacuation") |> render_click()
    assert has_element?(node, "#evacuation-preview-note")

    {:ok, details, _} = live(conn, ~p"/admin/jobs/#{job.id}")
    assert has_element?(details, "#job-detail")
    refute has_element?(details, "#retry-job")

    {:ok, certificates, _} = live(conn, ~p"/admin/audit?kind=certificates")
    refute has_element?(certificates, "#rotate-fleet-certificate")
    {:ok, _, _} = live(conn, ~p"/admin/audit?kind=lifecycle")

    export = get(conn, ~p"/admin/usage/export")
    assert export.status == 200
    assert export.resp_body =~ usage.id
    assert export.resp_body =~ "read-only-model"
    assert get(conn, ~p"/usage/export").resp_body != export.resp_body
  end

  for elevated <- [false, true] do
    @elevated elevated
    test "ordinary users cannot forge Control room changes, elevated=#{elevated}", %{conn: conn} do
      fixture = Marshall.TerminalFixtures.terminal_fixture()

      reader =
        if @elevated,
          do: Marshall.PasskeyFixture.verified_session(fixture.owner),
          else: fixture.owner

      conn = signed_in(conn, reader)
      target = Marshall.ComputeFixtures.user()
      vm_before = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
      host_before = Ledger.read!(Marshall.Compute.Host, id: fixture.host.id)
      operations_before = Ledger.read!(Marshall.Compute.Operation)

      for {path, events} <- [
            {"/admin/users",
             [
               {"set-role", %{"id" => target.id, "enabled" => "true"}},
               {"revoke-sessions", %{"id" => target.id}},
               {"invite", %{"email" => "blocked@example.test"}},
               {"delete-user",
                %{"user_id" => target.id, "confirmation" => to_string(target.email)}},
               {"reset-mfa", %{"id" => target.id}}
             ]},
            {"/admin/nodes/#{fixture.host.id}",
             [
               {"configure",
                %{"enabled" => "false", "overhead_cores" => "2", "overhead_memory_bytes" => "0"}},
               {"evacuate", %{}},
               {"control", %{"command" => "pause"}},
               {"approve", %{"id" => target.id, "key" => "test"}},
               {"replan", %{"id" => target.id, "key" => "test"}}
             ]},
            {"/admin/workloads",
             [
               {"lifecycle", %{"id" => fixture.vm.id, "kind" => "stop"}},
               {"relocate", %{"id" => fixture.vm.id}}
             ]},
            {"/admin/access",
             for(
               event <- ~w(revoke-key revoke-session revoke-grant),
               do: {event, %{"id" => target.id}}
             )},
            {"/admin/jobs", [{"retry", %{}}]},
            {"/admin/audit?kind=certificates", [{"rotate-certificate", %{}}]},
            {"/admin/git",
             [
               {"register", %{"git" => %{"owner" => "NixOS", "repo" => "nixpkgs"}}},
               {"refresh", %{"id" => target.id}},
               {"remove", %{"id" => target.id}}
             ]}
          ] do
        {:ok, view, _} = live(conn, path)

        for {event, payload} <- events do
          assert render_click(view, event, payload) =~
                   "Administrative changes require an administrator"
        end
      end

      assert Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id) == vm_before
      assert Ledger.read!(Marshall.Compute.Host, id: fixture.host.id) == host_before
      assert Ledger.read!(Marshall.Compute.Operation) == operations_before
      assert Ledger.read!(Marshall.Accounts.AdminEvent) == []
      assert Ledger.read!(Marshall.Enrico.Repository) == []
      refute Marshall.Accounts.Security.current(target.id).administrator
    end
  end

  for invalidation <- [:revoked, :expired, :retired] do
    @invalidation invalidation
    test "#{invalidation} ordinary logins lose mounted and exported read access", %{conn: conn} do
      reader = Marshall.ComputeFixtures.user()
      conn = signed_in(conn, reader)
      {:ok, view, _} = live(conn, ~p"/admin/users")
      token = get_session(conn, "user_token")
      {:ok, jti, _} = Marshall.Accounts.Login.verify(token, reader)

      case @invalidation do
        :revoked ->
          :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)

        :expired ->
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "UPDATE tokens SET expires_at = now() - interval '1 second' WHERE jti = $1",
            [jti],
            log: false
          )

        :retired ->
          Ledger.update!(reader, :security_state, %{deleted_at: Ledger.now()})
      end

      send(view.pid, :refresh)
      assert_redirect(view, ~p"/sign-in")
      assert {:error, {:redirect, _}} = live(conn, ~p"/admin/users")
      assert get(conn, ~p"/admin/usage/export").status == 404
    end
  end

  @spec signed_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    token = user.__metadata__[:token] || elem(AshAuthentication.Jwt.token_for_user(user), 1)

    conn
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end
end
