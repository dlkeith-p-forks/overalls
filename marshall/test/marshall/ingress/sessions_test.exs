defmodule Marshall.Ingress.SessionsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, VirtualMachine}
  alias Marshall.Ingress
  alias Marshall.Ingress.{Endpoint, Session, Token}

  @tag profile: :customer
  test "customer SSH admits owner but denies a persisted collaborator", c do
    assert {:ok, grant} = open(c)
    assert {:ok, _} = renew(c, grant)
    member = Marshall.ComputeFixtures.user()

    Ledger.create!(Marshall.Access.Grant, :grant, %{
      vm_id: c.vm.id,
      user_id: member.id,
      granted_by_id: c.owner.id,
      role: :manager
    })

    public = key_text()
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public}, actor: member)
    assert {:error, _} = open(%{c | public_key: public, key: key})
    [session] = Ledger.read!(Session, id: grant.binding.session_id)
    {ticket, hash} = Token.issue(:session)

    attrs =
      Map.take(session, [
        :service_id,
        :service_generation,
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :label,
        :expires_at
      ])

    Ledger.create!(Session, :record, Map.merge(attrs, %{key_id: key.id, token_hash: hash}))
    assert {:error, _} = renew(c, Map.put(grant, :ticket, ticket))
  end

  setup context do
    fixture =
      Marshall.TerminalFixtures.terminal_fixture(%{
        profile: Map.get(context, :profile, :standard)
      })

    {service_token, _} = Token.issue()

    {:ok, service} =
      Ingress.configure_service(
        %{
          name: "ssh-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: fixture.vm.host_id,
          token: service_token
        },
        actor: SystemActor.compute()
      )

    public_key = key_text()
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public_key}, actor: fixture.owner)
    [endpoint] = Ledger.read!(Endpoint, vm_id: fixture.vm.id)

    Map.merge(fixture, %{
      service_token: service_token,
      service: service,
      public_key: public_key,
      key: key,
      label: endpoint.label
    })
  end

  test "key status requires a gateway and neither admits a VM nor creates onboarding", c do
    args = %{service_token: c.service_token, public_key: c.public_key}

    counts = fn ->
      Enum.map(
        [Session, Marshall.SSH.Session, Marshall.SSH.Approval],
        &Ash.count!(&1, actor: SystemActor.compute())
      )
    end

    before = counts.()

    assert {:ok, %{status: :recognized}} =
             Ingress.ssh_key_status(args, actor: SystemActor.compute())

    assert {:error, _} = Ingress.ssh_key_status(args, actor: c.owner)

    assert {:error, _} =
             Ingress.ssh_key_status(%{args | service_token: "wrong"},
               actor: SystemActor.compute()
             )

    assert {:ok, %{status: :unknown}} =
             Ingress.ssh_key_status(%{args | public_key: key_text()},
               actor: SystemActor.compute()
             )

    assert {:ok, _} = Marshall.SSH.remove_key(%{id: c.key.id}, actor: c.owner)
    assert {:ok, %{status: :unknown}} = Ingress.ssh_key_status(args, actor: SystemActor.compute())
    assert counts.() == before
  end

  test "guest key eligibility binds durable account, offered key, Audi session and revocation",
       c do
    assert {:ok, account} =
             Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(c.owner.id) end)

    name = account.username
    assert name == "u#{account.uid}"
    assert {:ok, grant} = open(c)

    Ledger.update!(c.owner, :security_state, %{
      email: "9sshowner+#{System.unique_integer([:positive])}@example.test"
    })

    assert {:ok, renewed} = renew(c, grant)
    assert renewed.binding == grant.binding

    assert {:ok, same} =
             Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(c.owner.id) end)

    assert {same.id, same.username, same.uid} == {account.id, account.username, account.uid}

    binding = %{
      "host_id" => c.vm.host_id,
      "vm_id" => c.vm.id,
      "placement_id" => c.vm.current_placement_id,
      "execution_epoch" => c.vm.execution_epoch
    }

    assert {:error, :unauthorized} =
             Marshall.SSH.GuestAccess.authorize(binding, c.public_key, "someone-else")

    public_key = c.public_key
    assert {:ok, ^public_key} = Marshall.SSH.GuestAccess.authorize(binding, public_key, name)

    assert {:ok, %{revoked: true}} = Marshall.SSH.remove_key(%{id: c.key.id}, actor: c.owner)

    assert {:error, :unauthorized} =
             Marshall.SSH.GuestAccess.authorize(binding, c.public_key, name)
  end

  test "sessions bind execution, store only digests and audit admission but not heartbeat", c do
    assert {:ok, grant} = open(c)
    assert grant.ttl == 30_000
    assert grant.binding.vm_id == c.vm.id
    assert grant.binding.host_id == c.vm.host_id
    assert grant.binding.placement_id == c.vm.current_placement_id
    assert grant.binding.service == :ssh
    assert grant.binding.port == 22
    [session] = Ledger.read!(Session, id: grant.binding.session_id)
    assert session.key_id == c.key.id
    assert {:ok, hash} = Token.digest(grant.ticket, :session)
    assert session.token_hash == hash
    assert :error = Token.digest(grant.ticket)
    assert :error = Token.digest(c.service_token, :session)
    assert {:ok, renewed} = renew(c, grant)
    assert renewed.binding == grant.binding
    assert [version] = Ledger.read!(Session.Version, version_source_id: session.id)
    refute Map.has_key?(version.changes, "token_hash")
    refute Map.has_key?(version.changes, :token_hash)

    assert {:ok, %{closed: true}} =
             Ingress.close_ssh(params(c, grant), actor: SystemActor.compute())

    assert {:error, _} = renew(c, grant)
    assert {:error, _} = Ingress.open_ssh(open_params(c), actor: c.owner)
  end

  test "removing and re-registering a key never revives its old session", c do
    {:ok, grant} = open(c)
    assert {:ok, _} = Marshall.SSH.remove_key(%{id: c.key.id}, actor: c.owner)
    assert {:error, _} = renew(c, grant)
    assert {:error, _} = open(c)
    assert {:ok, replacement} = Marshall.SSH.add_key(%{public_key: c.public_key}, actor: c.owner)
    refute replacement.id == c.key.id
    assert {:error, _} = renew(c, grant)
    assert {:ok, _} = open(c)
  end

  test "gateway rotation and expiry invalidate old sessions", c do
    {:ok, grant} = open(c)
    {new_token, _} = Token.issue()

    {:ok, _} =
      Ingress.configure_service(
        %{name: c.service.name, role: :gateway, host_id: c.vm.host_id, token: new_token},
        actor: SystemActor.compute()
      )

    assert {:error, _} = renew(c, grant)
    c = %{c | service_token: new_token}
    assert {:error, _} = renew(c, grant)
    {:ok, new_grant} = open(c)
    [session] = Ledger.read!(Session, id: new_grant.binding.session_id)
    Ledger.update!(session, :renew, %{expires_at: DateTime.add(Ledger.now(), -1)})
    assert {:error, _} = renew(c, new_grant)
  end

  test "changed execution and stale host evidence deny both old and new authority", c do
    {:ok, grant} = open(c)
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    Ledger.intent!(vm, %{
      generation: vm.generation + 1,
      desired_state: :stopped
    })

    assert {:error, _} = renew(c, grant)
    assert {:error, _} = open(c)
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -60)})
    assert {:error, _} = open(c)
  end

  test "stale host evidence alone stops renewal of an otherwise running VM", c do
    {:ok, grant} = open(c)
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -60)})
    assert {:error, _} = renew(c, grant)
    assert {:error, _} = open(c)
  end

  # @cc [owner:ghuntley,label:verification;recovery] ssh-renewal-across-lilly-restart
  # While Lilly reconnects (no session, or a new one without its first report),
  # SSH renewal MUST be temporarily_unavailable and admission MUST be refused;
  # once the new session reports, renewal MUST keep the exact binding.
  test "SSH renewal across a Lilly restart is inconclusive, then keeps the binding", c do
    {:ok, grant} = open(c)
    request = %{"version" => 1, "session_token" => grant.ticket}
    disconnect!(c)

    assert {:error, :temporarily_unavailable} =
             Ingress.ControlRequests.handle("ssh-renew", c.service_token, request)

    assert {:error, :unauthorized} = control_open(c)
    [host] = Ledger.read!(Host, id: c.vm.host_id)

    Ledger.update!(host, :connect, %{
      connection_session_id: Ash.UUID.generate(),
      connection_epoch: host.connection_epoch + 1,
      report_sequence: 0,
      reported_at: nil
    })

    assert {:error, :temporarily_unavailable} =
             Ingress.ControlRequests.handle("ssh-renew", c.service_token, request)

    assert {:error, :unauthorized} = control_open(c)
    report!(c)
    assert {:ok, renewed} = renew(c, grant)
    assert renewed.binding == grant.binding
  end

  # @cc [owner:ghuntley,label:verification;security] ssh-renewal-revocation-stays-conclusive
  # Key removal, write revocation, and a stop with a newer generation MUST stay
  # conclusive refusals while Lilly reconnects.
  test "real revocations stay conclusive for SSH renewal while Lilly reconnects", c do
    {:ok, grant} = open(c)
    member = Marshall.ComputeFixtures.user()
    public_key = key_text()
    {:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: member)
    {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :operator)
    member_context = %{c | public_key: public_key}
    {:ok, member_grant} = open(member_context)
    other_key = key_text()
    {:ok, other} = Marshall.SSH.add_key(%{public_key: other_key}, actor: c.owner)
    {:ok, other_grant} = open(%{c | public_key: other_key, key: other})
    disconnect!(c)

    renew =
      &Ingress.ControlRequests.handle("ssh-renew", c.service_token, %{
        "version" => 1,
        "session_token" => &1.ticket
      })

    assert {:error, :temporarily_unavailable} = renew.(grant)
    assert {:ok, _} = Marshall.SSH.remove_key(%{id: other.id}, actor: c.owner)
    assert {:error, :unauthorized} = renew.(other_grant)
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :viewer)
    assert {:error, reason} = renew.(member_grant)
    assert reason in [:unauthorized, :forbidden]
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    Ledger.intent!(vm, %{generation: vm.generation + 1, desired_state: :stopped})
    assert {:error, :unauthorized} = renew.(grant)
  end

  test "downgrading an operator to viewer stops an existing session", c do
    member = Marshall.ComputeFixtures.user()
    public_key = key_text()
    {:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: member)
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :operator)
    member_context = %{c | public_key: public_key}
    {:ok, grant} = open(member_context)
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :viewer)
    assert {:error, _} = renew(member_context, grant)
  end

  test "web-only replacement revokes SSH renewal and cannot open a new SSH stream", c do
    member = Marshall.ComputeFixtures.user()
    public_key = key_text()
    {:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: member)
    {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :operator)
    context = %{c | public_key: public_key}
    {:ok, grant} = open(context)
    {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :web)
    assert {:error, _} = renew(context, grant)
    assert {:error, _} = open(context)
  end

  test "a tombstoned actor can neither renew nor open SSH sessions before durable cleanup", c do
    member = Marshall.ComputeFixtures.user()
    public_key = key_text()
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public_key}, actor: member)
    {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :operator)
    member_context = %{c | public_key: public_key, key: key}
    {:ok, grant} = open(member_context)
    assert {:ok, _} = renew(member_context, grant)

    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

    assert {:ok, %{deleting: true}} =
             Marshall.Accounts.User
             |> Ash.ActionInput.for_action(
               :delete_user,
               %{user_id: member.id, confirmation: to_string(member.email)},
               actor: admin
             )
             |> Ash.run_action()

    # Bounded durable cleanup has not run yet: the member's grant and key rows
    # remain live, so this window is fenced only by the committed tombstone.
    assert [_] = Ledger.read!(Marshall.Access.Grant, user_id: member.id)
    assert [_] = Ledger.read!(Marshall.SSH.Key, user_id: member.id)
    assert {:error, _} = renew(member_context, grant)
    assert {:error, _} = open(member_context)

    [deletion] = Ledger.read!(Marshall.Accounts.UserDeletion, user_id: member.id)

    assert {:ok, %{complete: true}} =
             Marshall.Accounts.DeleteUserMachines.run(
               %Ash.ActionInput{arguments: %{primary_key: %{"id" => deletion.id}}},
               [],
               %{actor: SystemActor.compute()}
             )

    assert {:error, _} = renew(member_context, grant)
    assert {:error, _} = open(member_context)

    # The VM owner's own authority survives an unrelated member retirement.
    assert {:ok, owner_grant} = open(c)
    assert {:ok, _} = renew(c, owner_grant)
  end

  test "DNS identities and gateways on another host cannot admit a stream", c do
    %{host: other} = Marshall.ComputeFixtures.host_fixture()

    for {role, host_id} <- [{:dns, nil}, {:gateway, other.id}] do
      {token, _} = Token.issue()

      {:ok, _} =
        Ingress.configure_service(
          %{name: Ash.UUID.generate(), role: role, host_id: host_id, token: token},
          actor: SystemActor.compute()
        )

      assert {:error, _} = open(%{c | service_token: token})
    end
  end

  property "current sharing roles alone decide new SSH admission", c do
    member = Marshall.ComputeFixtures.user()
    public_key = key_text()
    {:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: member)
    member_context = %{c | public_key: public_key}

    check all(
            roles <-
              list_of(member_of([:viewer, :operator, :manager, :revoked]),
                min_length: 1,
                max_length: 8
              ),
            max_runs: 12
          ) do
      Enum.each(roles, fn role ->
        [host] = Ledger.read!(Host, id: c.vm.host_id)
        Ledger.update!(host, :report, %{reported_at: Ledger.now()})
        assert {:ok, _} = Marshall.TerminalFixtures.grant(c, member, role)

        case {role, open(member_context)} do
          {allowed, {:ok, grant}} when allowed in [:operator, :manager] ->
            assert {:ok, _} = renew(member_context, grant)
            assert {:ok, _} = Ingress.close_ssh(params(c, grant), actor: SystemActor.compute())

          {denied, {:error, _}} when denied in [:viewer, :revoked] ->
            :ok

          other ->
            flunk("unexpected authorization result: #{inspect(elem(other, 0))}")
        end
      end)
    end
  end

  test "cleanup removes expired rows but retains their audit evidence", c do
    {:ok, grant} = open(c)
    [session] = Ledger.read!(Session, id: grant.binding.session_id)
    Ledger.update!(session, :renew, %{expires_at: DateTime.add(Ledger.now(), -8 * 86_400)})
    AshOban.schedule(Session, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [] = Ledger.read!(Session, id: session.id)
    assert [_] = Ledger.read!(Session.Version, version_source_id: session.id)
    assert [_] = Ledger.read!(Marshall.SSH.Key, id: c.key.id)
  end

  test "admission enforces its live session cap and expired rows release a slot", c do
    {:ok, grant} = open(c)
    [template] = Ledger.read!(Session, id: grant.binding.session_id)
    template = Ledger.update!(template, :renew, %{expires_at: DateTime.add(Ledger.now(), 60)})
    for _ <- 1..127, do: copy_session(template, DateTime.add(Ledger.now(), 60))
    refresh_host(c)
    assert {:error, error} = open(c)
    assert Exception.message(error) =~ "session_limit"
    Ledger.update!(template, :renew, %{expires_at: DateTime.add(Ledger.now(), -1)})
    assert {:ok, _} = open(c)
  end

  test "cleanup durably continues after a full batch without deleting recent rows", c do
    {:ok, grant} = open(c)
    [template] = Ledger.read!(Session, id: grant.binding.session_id)
    cutoff = DateTime.add(Ledger.now(), -8 * 86_400)
    expired = for _ <- 1..501, do: copy_session(template, cutoff)
    AshOban.schedule(Session, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert length(Ledger.read!(Session)) == 2
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [%{id: id}] = Ledger.read!(Session)
    assert id == template.id
    assert [_] = Ledger.read!(Session.Version, version_source_id: hd(expired).id)
  end

  defp copy_session(template, expires_at) do
    {_, hash} = Token.issue(:session)

    attrs =
      Map.take(template, [
        :service_id,
        :service_generation,
        :key_id,
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :label
      ])

    Ledger.create!(
      Session,
      :record,
      Map.merge(attrs, %{token_hash: hash, expires_at: expires_at})
    )
  end

  defp refresh_host(c) do
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
  end

  defp key_text,
    do:
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

  defp open_params(c),
    do: %{service_token: c.service_token, public_key: c.public_key, label: c.label}

  defp open(c), do: Ingress.open_ssh(open_params(c), actor: SystemActor.compute())
  defp params(c, grant), do: %{service_token: c.service_token, session_token: grant.ticket}
  defp renew(c, grant), do: Ingress.renew_ssh(params(c, grant), actor: SystemActor.compute())

  defp control_open(c),
    do:
      Ingress.ControlRequests.handle("ssh-open", c.service_token, %{
        "version" => 1,
        "public_key" => c.public_key,
        "label" => c.label
      })

  defp disconnect!(c) do
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    {:ok, :ok} = Marshall.Compute.HostReports.disconnect(host.id, host.connection_epoch)
  end

  defp report!(c) do
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
  end
end
