defmodule Marshall.EditorTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  import ExUnit.CaptureLog
  alias Marshall.Accounts.GuestAccount
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.EditorFixture, as: F

  setup context do
    previous = Application.get_env(:marshall, :ingress_editor_release)
    Application.put_env(:marshall, :ingress_editor_release, F.descriptor())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, :ingress_editor_release, previous),
        else: Application.delete_env(:marshall, :ingress_editor_release)
    end)

    F.new(Map.get(context, :profile, :standard))
  end

  test "writer opens a fixed-port, exact-account lease and renewal retains every binding", c do
    assert {:ok, launch} = Marshall.Editor.launch(%{vm_id: c.vm.id}, actor: c.owner)
    cookie = F.cookie(c, c.owner)
    assert launch.hostname == cookie.hostname
    assert {:ok, grant} = F.open(c, cookie)
    assert OverallsProtocol.EditorConnect.valid?(grant.binding)
    assert grant.binding.port == 4444 and grant.binding.service == :editor
    assert grant.binding.user_id == c.owner.id and grant.binding.uid >= 200_000
    assert grant.binding.session_id == c.connection.session_id
    assert grant.ttl in 1..30_000
    assert {:ok, renewed} = F.renew(c, grant.ticket)
    assert renewed.binding == grant.binding
  end

  # @cc [owner:ghuntley,label:verification;protocol] editor-zone-authority-refusal
  # A single-label generic ingress zone MUST NOT return an unusable editor
  # origin. The real launch action MUST refuse and roll back account allocation.
  test "a single-label zone refuses editor launch before allocating a guest account", c do
    previous = Application.fetch_env!(:marshall, :ingress_zone)
    Application.put_env(:marshall, :ingress_zone, "local")
    before = Ledger.read!(GuestAccount)

    try do
      assert {:error, _} = Marshall.Editor.launch(%{vm_id: c.vm.id}, actor: c.owner)
      assert Ledger.read!(GuestAccount) == before
    after
      Application.put_env(:marshall, :ingress_zone, previous)
    end
  end

  test "two writers receive separate origins and cannot exchange account cookies", c do
    writer = Marshall.ComputeFixtures.user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :operator)
    first = F.cookie(c, c.owner)
    second = F.cookie(c, writer)
    refute first.hostname == second.hostname
    assert {:ok, first_grant} = F.open(c, first)
    assert {:ok, second_grant} = F.open(c, second)
    refute first_grant.binding.guest_account_id == second_grant.binding.guest_account_id
    assert {:error, _} = F.open(c, %{first | cookie: second.cookie})
    assert {:error, _} = F.open(c, %{second | cookie: first.cookie})
    {login, _} = F.begin_login(c, first.label)

    assert {:error, _} =
             Marshall.Editor.authorize_editor_login(
               %{ticket: login.ticket, login_token: second.token},
               actor: writer
             )
  end

  property "current sharing roles independently decide editor write admission", c do
    check all(role <- member_of([:web, :viewer, :operator, :manager, :revoked]), max_runs: 12) do
      F.fresh(c)
      member = Marshall.ComputeFixtures.user()
      token = Marshall.TerminalFixtures.user_token(member)
      {:ok, jti, _} = Marshall.Accounts.Login.verify(token, member)
      actor = Marshall.Accounts.Security.bind(member, jti)
      assert {:ok, _} = Marshall.TerminalFixtures.grant(c, member, role)
      result = Marshall.Editor.launch(%{vm_id: c.vm.id}, actor: actor)
      assert match?({:ok, _}, result) == role in [:operator, :manager]
    end
  end

  @tag profile: :customer
  test "Customer requires its exact owner while ordinary web stays denied", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, _} = F.open(c, cookie)
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
    assert {:error, _} = Marshall.Editor.launch(%{vm_id: c.vm.id}, actor: admin)
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

    assert {:error, _} =
             Marshall.Ingress.open_web(
               %{service_token: c.service_token, label: endpoint.label, app_port: 4444},
               actor: SystemActor.compute()
             )
  end

  test "state mismatch and replay do not issue a second cookie", c do
    {login, state} = F.begin_login(c, F.label(c, c.owner))

    assert {:ok, approved} =
             Marshall.Editor.authorize_editor_login(%{ticket: login.ticket, login_token: c.token},
               actor: c.owner
             )

    request = %{
      service_token: c.service_token,
      ticket: login.ticket,
      code: approved.code,
      state: state
    }

    wrong = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:error, _} =
             Marshall.Editor.exchange_editor_login(%{request | state: wrong},
               actor: SystemActor.compute()
             )

    assert {:ok, _} = Marshall.Editor.exchange_editor_login(request, actor: SystemActor.compute())

    assert {:error, _} =
             Marshall.Editor.exchange_editor_login(request, actor: SystemActor.compute())

    assert length(Ledger.read!(Marshall.Editor.Credential)) == 1
  end

  test "email changes preserve existing editor credentials, lease and guest binding", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    [account] = Ledger.read!(GuestAccount, id: grant.binding.guest_account_id)
    user = Marshall.Accounts.Security.current(c.owner.id)
    Ledger.update!(user, :security_state, %{email: "9new.name+tag@example.test"})
    assert [account] == Ledger.read!(GuestAccount, id: account.id)
    assert {:ok, renewed} = F.renew(c, grant.ticket)
    assert renewed.binding == grant.binding
    assert {:ok, opened} = F.open(c, cookie)
    assert opened.binding == grant.binding
    assert [account] == Ledger.read!(GuestAccount, user_id: user.id)
  end

  # @cc [owner:ghuntley,label:verification;security] editor-pending-login-email-continuity
  # Email edits between login begin, approval and exchange MUST preserve the
  # GuestAccount origin and permit the existing verified login to complete.
  test "pending editor approval and exchange survive email changes", c do
    label = F.label(c, c.owner)
    [account] = Ledger.read!(GuestAccount, user_id: c.owner.id)
    {login, state} = F.begin_login(c, label)
    user = Marshall.Accounts.Security.current(c.owner.id)
    updated = Ledger.update!(user, :security_state, %{email: "root+editor@example.test"})

    assert {:ok, approved} =
             Marshall.Editor.authorize_editor_login(%{ticket: login.ticket, login_token: c.token},
               actor: c.owner
             )

    Ledger.update!(updated, :security_state, %{email: "9editor@elsewhere.test"})

    assert {:ok, result} =
             Marshall.Editor.exchange_editor_login(
               %{
                 service_token: c.service_token,
                 ticket: login.ticket,
                 code: approved.code,
                 state: state
               },
               actor: SystemActor.compute()
             )

    cookie = Map.merge(result, %{label: label, token: c.token})
    assert {:ok, grant} = F.open(c, cookie)
    assert grant.binding.guest_account_id == account.id
    assert {grant.binding.username, grant.binding.uid} == {account.username, account.uid}
    assert F.label(c, c.owner) == label
    assert {:ok, renewed} = F.renew(c, grant.ticket)
    assert renewed.binding == grant.binding
    assert [account] == Ledger.read!(GuestAccount, user_id: c.owner.id)
  end

  test "domain-only email changes preserve the permanent account incarnation", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    user = Marshall.Accounts.Security.current(c.owner.id)
    [local, _] = String.split(to_string(user.email), "@")
    Ledger.update!(user, :security_state, %{email: local <> "@elsewhere.test"})
    assert {:ok, renewed} = F.renew(c, grant.ticket)
    assert renewed.binding == grant.binding
  end

  test "retirement, login revocation and lease expiry each refuse further authority", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, cookie.token)
    assert {:error, _} = F.renew(c, grant.ticket)
    assert {:error, _} = F.open(c, cookie)
    new_token = Marshall.TerminalFixtures.user_token(c.owner)
    new_cookie = F.cookie(%{c | token: new_token}, c.owner)
    assert {:ok, second} = F.open(c, new_cookie)
    {:ok, hash} = Marshall.Editor.Token.digest(second.ticket, :lease)
    [lease] = Ledger.read!(Marshall.Editor.Lease, token_hash: hash)
    Ledger.update!(lease, :renew, %{expires_at: DateTime.add(Ledger.now(), -1)})
    assert {:error, _} = F.renew(c, second.ticket)
    [account] = Ledger.read!(GuestAccount, id: second.binding.guest_account_id)
    Ledger.update!(account, :retire, %{retired_at: Ledger.now()})
    assert {:error, _} = F.open(c, new_cookie)
  end

  test "fresh sign-in recovers while a stale editor cookie remains authentication-required", c do
    stale = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, stale)
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, stale.token)
    request = %{"version" => 1, "label" => stale.label, "cookie" => stale.cookie}

    assert {:error, :authentication_required} =
             Marshall.Ingress.ControlRequests.handle("editor-open", c.service_token, request)

    assert {:error, :authentication_required} =
             Marshall.Ingress.ControlRequests.handle("editor-renew", c.service_token, %{
               "version" => 1,
               "stream_token" => grant.ticket
             })

    fresh_token = Marshall.TerminalFixtures.user_token(c.owner)
    fresh = F.cookie(%{c | token: fresh_token}, c.owner)
    assert fresh.hostname == stale.hostname

    assert {:error, :authentication_required} =
             Marshall.Ingress.ControlRequests.handle("editor-open", c.service_token, request)

    assert {:ok, _} =
             Marshall.Ingress.ControlRequests.handle(
               "editor-open",
               c.service_token,
               %{request | "cookie" => fresh.cookie}
             )
  end

  test "control refusals distinguish current write denial from route execution unavailability",
       c do
    writer = Marshall.ComputeFixtures.user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :operator)
    cookie = F.cookie(c, writer)
    request = %{"version" => 1, "label" => cookie.label, "cookie" => cookie.cookie}
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :revoked)

    assert {:error, :forbidden} =
             Marshall.Ingress.ControlRequests.handle("editor-open", c.service_token, request)

    owner_cookie = F.cookie(c, c.owner)
    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -60)})

    assert {:error, :unauthorized} =
             Marshall.Ingress.ControlRequests.handle("editor-open", c.service_token, %{
               "version" => 1,
               "label" => owner_cookie.label,
               "cookie" => owner_cookie.cookie
             })
  end

  test "membership revocation, execution changes and closed leases cannot renew", c do
    writer = Marshall.ComputeFixtures.user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :operator)
    cookie = F.cookie(c, writer)
    assert {:ok, grant} = F.open(c, cookie)
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :revoked)
    assert {:error, _} = F.renew(c, grant.ticket)
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :operator)

    assert {:ok, _} =
             Marshall.Editor.close_editor(
               %{service_token: c.service_token, stream_token: grant.ticket},
               actor: SystemActor.compute()
             )

    assert {:error, _} = F.renew(c, grant.ticket)
    assert {:ok, other} = F.open(c, cookie)
    Ledger.intent!(c.vm, %{desired_state: :stopped, generation: c.vm.generation + 1})
    assert {:error, _} = F.renew(c, other.ticket)
  end

  test "generic endpoint policy changes have no effect on editor authority", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

    Ledger.update!(endpoint, :change_policy, %{
      primary_port: 9090,
      visibility: :public,
      policy_revision: endpoint.policy_revision + 1
    })

    assert {:ok, renewed} = F.renew(c, grant.ticket)
    assert renewed.binding == grant.binding
  end

  # @cc [owner:ghuntley,label:verification;recovery] editor-renewal-across-lilly-restart
  # A Lilly restart (disconnect, then a new control session that has not yet
  # reported) MUST make renewal inconclusive, never a revocation; once the new
  # session reports, renewal MUST succeed with the unchanged binding. The
  # reconnect window MUST NOT open new admissions.
  test "renewal across a Lilly restart is inconclusive while reconnecting, then keeps the binding",
       c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    renew = %{"version" => 1, "stream_token" => grant.ticket}
    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
    assert {:ok, :ok} = Marshall.Compute.HostReports.disconnect(host.id, host.connection_epoch)

    assert {:error, :temporarily_unavailable} =
             Marshall.Ingress.ControlRequests.handle("editor-renew", c.service_token, renew)

    open = %{"version" => 1, "label" => cookie.label, "cookie" => cookie.cookie}

    assert {:error, :unauthorized} =
             Marshall.Ingress.ControlRequests.handle("editor-open", c.service_token, open)

    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)

    Ledger.update!(host, :connect, %{
      connection_session_id: Ash.UUID.generate(),
      connection_epoch: host.connection_epoch + 1,
      report_sequence: 0,
      reported_at: nil
    })

    assert {:error, :temporarily_unavailable} =
             Marshall.Ingress.ControlRequests.handle("editor-renew", c.service_token, renew)

    :ok = F.fresh(c)
    assert {:ok, renewed} = F.renew(c, grant.ticket)
    assert renewed.binding == grant.binding
  end

  # @cc [owner:ghuntley,label:verification;security] editor-renewal-revocation-stays-conclusive
  # Real revocations MUST stay conclusive even while Lilly reconnects: a newer
  # generation or stop, sign-out, and an aged-out report on a live session.
  test "real revocations still end editor renewal conclusively, even while reconnecting", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    renew = %{"version" => 1, "stream_token" => grant.ticket}
    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -60)})

    assert {:error, :unauthorized} =
             Marshall.Ingress.ControlRequests.handle("editor-renew", c.service_token, renew)

    :ok = F.fresh(c)
    assert {:ok, _} = F.renew(c, grant.ticket)
    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
    assert {:ok, :ok} = Marshall.Compute.HostReports.disconnect(host.id, host.connection_epoch)
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, cookie.token)

    assert {:error, :authentication_required} =
             Marshall.Ingress.ControlRequests.handle("editor-renew", c.service_token, renew)

    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
    Ledger.update!(host, :connect, %{connection_session_id: Ash.UUID.generate()})
    :ok = F.fresh(c)
    other = F.cookie(%{c | token: Marshall.TerminalFixtures.user_token(c.owner)}, c.owner)
    assert {:ok, next} = F.open(c, other)
    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
    assert {:ok, :ok} = Marshall.Compute.HostReports.disconnect(host.id, host.connection_epoch)
    Ledger.intent!(c.vm, %{desired_state: :stopped, generation: c.vm.generation + 1})

    assert {:error, :unauthorized} =
             Marshall.Ingress.ControlRequests.handle("editor-renew", c.service_token, %{
               "version" => 1,
               "stream_token" => next.ticket
             })
  end

  test "a changed gateway generation refuses existing cookie and lease authority", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    [service] = Ledger.read!(Marshall.Ingress.Service, id: c.service.id)
    Ledger.update!(service, :rotate, %{generation: service.generation + 1})
    assert {:error, _} = F.open(c, cookie)
    assert {:error, _} = F.renew(c, grant.ticket)
  end

  test "operational retention preserves referenced credentials and independent audit versions",
       c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, grant} = F.open(c, cookie)
    {:ok, lease_hash} = Marshall.Editor.Token.digest(grant.ticket, :lease)
    [lease] = Ledger.read!(Marshall.Editor.Lease, token_hash: lease_hash)
    [credential] = Ledger.read!(Marshall.Editor.Credential, id: lease.credential_id)
    old = DateTime.add(Ledger.now(), -8 * 86_400)
    {_, credential_hash} = Marshall.Editor.Token.issue(:cookie)

    retained =
      credential
      |> Map.take([
        :user_id,
        :login_jti,
        :guest_account_id,
        :vm_id,
        :service_id,
        :service_generation,
        :label
      ])
      |> Map.merge(%{token_hash: credential_hash, expires_at: old})
      |> then(&Ledger.create!(Marshall.Editor.Credential, :record, &1))

    {_, retained_lease_hash} = Marshall.Editor.Token.issue(:lease)

    retained_lease =
      lease
      |> Map.take([
        :service_id,
        :service_generation,
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :connection_session_id,
        :label,
        :user_id,
        :guest_account_id,
        :uid,
        :username,
        :editor_protocol,
        :editor_commit,
        :editor_release,
        :editor_origin,
        :expires_at
      ])
      |> Map.merge(%{token_hash: retained_lease_hash, credential_id: retained.id})
      |> then(&Ledger.create!(Marshall.Editor.Lease, :record, &1))

    AshOban.schedule(Marshall.Editor.Lease, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [_] = Ledger.read!(Marshall.Editor.Credential, id: retained.id)
    Ledger.update!(retained_lease, :renew, %{expires_at: old})
    AshOban.schedule(Marshall.Editor.Lease, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [] = Ledger.read!(Marshall.Editor.Lease, id: retained_lease.id)
    assert [] = Ledger.read!(Marshall.Editor.Credential, id: retained.id)

    assert [_] =
             Ledger.read!(Marshall.Editor.Lease.Version, version_source_id: retained_lease.id)

    assert [_] =
             Ledger.read!(Marshall.Editor.Credential.Version, version_source_id: retained.id)
  end

  test "ordinary web configuration, admission and login cannot select the reserved editor port",
       c do
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

    assert {:error, _} =
             Marshall.Ingress.configure_endpoint(
               %{
                 vm_id: c.vm.id,
                 expected_revision: endpoint.policy_revision,
                 primary_port: 4444,
                 visibility: :public
               },
               actor: c.owner
             )

    assert [^endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, id: endpoint.id)

    assert_raise Ash.Error.Invalid, fn ->
      Ledger.update!(endpoint, :change_policy, %{primary_port: 4444, visibility: :public})
    end

    assert [^endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, id: endpoint.id)
    request = %{service_token: c.service_token, label: endpoint.label, app_port: 4444}
    assert {:error, _} = Marshall.Ingress.open_web(request, actor: SystemActor.compute())

    assert {:error, _} =
             Marshall.Ingress.begin_web_login(
               Map.put(request, :state_digest, String.duplicate("a", 64)),
               actor: SystemActor.compute()
             )

    assert Ledger.read!(Marshall.Ingress.WebStream) == []
    assert Ledger.read!(Marshall.Ingress.WebLogin) == []
    assert {:ok, _} = F.open(c, F.cookie(c, c.owner))
  end

  test "unsupported or differently approved releases cannot launch", c do
    Application.put_env(:marshall, :ingress_editor_release, %{
      c.descriptor
      | "release" => String.duplicate("c", 64)
    })

    assert {:error, _} = Marshall.Editor.launch(%{vm_id: c.vm.id}, actor: c.owner)
    Application.put_env(:marshall, :ingress_editor_release, c.descriptor)
    old = Marshall.TerminalFixtures.terminal_fixture()
    token = Marshall.TerminalFixtures.user_token(old.owner)
    {:ok, jti, _} = Marshall.Accounts.Login.verify(token, old.owner)

    assert {:error, _} =
             Marshall.Editor.launch(%{vm_id: old.vm.id},
               actor: Marshall.Accounts.Security.bind(old.owner, jti)
             )
  end

  test "outer rollback discards durable transitions and structured outcome events", c do
    {login, _} = F.begin_login(c, F.label(c, c.owner))
    before = length(Ledger.read!(Marshall.Editor.Login.Version))

    logs =
      capture_log([level: :info, metadata: [:event]], fn ->
        assert {:error, :rollback_probe} =
                 Ledger.transaction(fn ->
                   assert {:ok, _} =
                            Marshall.Editor.authorize_editor_login(
                              %{ticket: login.ticket, login_token: c.token},
                              actor: c.owner
                            )

                   Ledger.rollback(:rollback_probe)
                 end)
      end)

    refute logs =~ "editor.authority"
    refute logs =~ login.ticket
    assert length(Ledger.read!(Marshall.Editor.Login.Version)) == before
    assert [%{status: :pending}] = Ledger.read!(Marshall.Editor.Login)
  end

  test "Control room audit is bounded, freshly authorized and omits proofs", c do
    cookie = F.cookie(c, c.owner)
    assert {:ok, _} = F.open(c, cookie)
    assert {:ok, _} = Marshall.Editor.audit(%{}, actor: c.owner)
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
    assert {:ok, %{items: items}} = Marshall.Editor.audit(%{}, actor: admin)
    assert length(items) in 1..100
    encoded = inspect(items)
    refute encoded =~ cookie.cookie
    refute encoded =~ "token_hash"
    refute encoded =~ "username"
    refute encoded =~ "login_jti"
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, c.token)
    assert {:error, _} = Marshall.Editor.audit(%{}, actor: c.owner)
  end
end
