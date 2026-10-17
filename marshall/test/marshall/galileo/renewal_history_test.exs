defmodule Marshall.Galileo.RenewalHistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Compute.{HostReports, Ledger}
  alias Marshall.Galileo
  alias Marshall.Galileo.{Authorizations, Credentials, Integration, PeerTokens}
  @moduletag capture_log: true

  @type fixture :: %{
          host: Marshall.Compute.Host.t(),
          owner: Marshall.Accounts.User.t(),
          vm: Marshall.Compute.VirtualMachine.t(),
          connection: %{session_id: String.t(), epoch: pos_integer()},
          report: OverallsProtocol.report()
        }
  # Elixir typespecs cannot express literal binary map keys. Bound wire values
  # here and validate the closed binding in the construction helper below.
  @type binding_wire :: %{required(String.t()) => String.t() | pos_integer()}
  @type wire :: %{required(String.t()) => String.t() | binding_wire()}

  @type operation :: :join | :leave | :attach | :detach | :team | :personal
  @type model :: %{member: boolean(), attached: boolean(), team: boolean()}

  # @cc [owner:ghuntley,label:verification;security] personal-integration-explicit-history
  # Personal-owner histories MUST exercise public attachment changes and derive
  # admission from a separate attachment model. Refusals and every renewal MUST
  # preserve durable credentials, provenance, attachments and mutation audits.
  property "personal owners require explicit attachments for admission and renewal" do
    check all(
            peer <- boolean(),
            tail <- list_of(boolean(), max_length: 12),
            stale_delta <- integer(1..10),
            max_runs: 15
          ) do
      fixture = fresh_fixture()
      outsider = Marshall.ComputeFixtures.user()
      name = "personal-" <> binary_part(Ash.UUID.generate(), 0, 12)
      {:ok, integration} = configure_peer(name, fixture, peer, 0)
      {token, wire} = authority(fixture, name)
      before = snapshot(integration.id)
      assert {:error, :unauthorized} = Authorizations.authorize(token, wire)
      assert_renewal(Authorizations.renew(token, wire), false)
      assert snapshot(integration.id) == before

      for {attached, sequence} <- Enum.with_index([true, false, true, false] ++ tail, 2) do
        operation = if attached, do: :attach_integration, else: :detach_integration

        assert {:ok, _} =
                 apply(Galileo, operation, [
                   %{name: name, vm_id: fixture.vm.id},
                   [actor: fixture.owner]
                 ])

        fresh_report(fixture, sequence)
        before = snapshot(integration.id)

        for mutation <- [:attach_integration, :detach_integration, :remove_integration] do
          arguments =
            if mutation == :remove_integration,
              do: %{name: name},
              else: %{name: name, vm_id: fixture.vm.id}

          refusal_logs =
            ExUnit.CaptureLog.capture_log([level: :info, metadata: [:event]], fn ->
              assert {:error, _} = apply(Galileo, mutation, [arguments, [actor: outsider]])
            end)

          refute refusal_logs =~ "galileo.integration_configured"
          assert snapshot(integration.id) == before
        end

        assert_renewal(Authorizations.renew(token, wire), attached)
        assert snapshot(integration.id) == before
        authorization = Authorizations.authorize(token, wire)
        assert match?({:ok, _}, authorization) == attached

        if not attached do
          assert authorization == {:error, :unauthorized}
          assert snapshot(integration.id) == before
        end

        current = snapshot(integration.id)

        for {field, value} <- [
              {"execution_epoch", fixture.vm.execution_epoch + stale_delta},
              {"placement_id", Ash.UUID.generate()}
            ] do
          stale_wire = put_in(wire, ["binding", field], value)
          assert {:error, :unauthorized} = Authorizations.authorize(token, stale_wire)
          assert_renewal(Authorizations.renew(token, stale_wire), false)
          assert snapshot(integration.id) == current
        end

        for event <- Ledger.read!(Marshall.Accounts.AdminEvent, target_id: integration.id),
            event.kind in [:galileo_attach, :galileo_detach],
            do: assert(event.actor_id == fixture.owner.id)
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] integration-supported-retirement-history
  # Supported account retirement and integration removal MUST refuse subsequent
  # admission and renewal despite prior successful attachment. Refused reads
  # MUST preserve the post-mutation durable snapshot and mutation audit rows.
  property "supported retirement and removal revoke previously attached personal integrations" do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

    check all(peer <- boolean(), attempts <- integer(1..3), max_runs: 4) do
      for terminal <- [:remove, :retire] do
        fixture = fresh_fixture()
        name = "retire-" <> binary_part(Ash.UUID.generate(), 0, 12)
        {:ok, integration} = configure_peer(name, fixture, peer, 0)

        assert {:ok, _} =
                 Galileo.attach_integration(%{name: name, vm_id: fixture.vm.id},
                   actor: fixture.owner
                 )

        {token, wire} = authority(fixture, name)
        assert {:ok, _} = Authorizations.authorize(token, wire)
        assert_renewal(Authorizations.renew(token, wire), true)

        case terminal do
          :remove ->
            assert {:ok, _} = Galileo.remove_integration(%{name: name}, actor: fixture.owner)

          :retire ->
            assert {:ok, _} =
                     Marshall.Accounts.User
                     |> Ash.ActionInput.for_action(
                       :delete_user,
                       %{user_id: fixture.owner.id, confirmation: to_string(fixture.owner.email)},
                       actor: admin
                     )
                     |> Ash.run_action()
        end

        before = snapshot(integration.id)

        for _ <- 1..attempts do
          assert {:error, :unauthorized} = Authorizations.authorize(token, wire)
          assert_renewal(Authorizations.renew(token, wire), false)
          assert snapshot(integration.id) == before
        end
      end
    end
  end

  property "archived teams refuse integration admission, renewal, reads and peer tokens" do
    check all(attached <- boolean(), peer <- boolean(), attempts <- integer(1..3), max_runs: 8) do
      fixture = fresh_fixture()
      manager = Marshall.ComputeFixtures.user()

      {:ok, team} =
        Marshall.Teams.create_team(
          %{name: "archive-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
          actor: manager
        )

      {:ok, _} =
        Marshall.Teams.set_team_member(
          %{
            team_id: team.id,
            email: fixture.owner.email,
            role: :member,
            idempotency_key: Ash.UUID.generate()
          },
          actor: manager
        )

      name = "archive-" <> binary_part(Ash.UUID.generate(), 0, 12)

      {:ok, integration} =
        Galileo.configure_integration(
          %{
            name: name,
            target: if(peer, do: nil, else: "https://v0.example.test"),
            peer: peer,
            peer_vm_id: if(peer, do: fixture.vm.id),
            team_id: team.id,
            headers: [%{kind: :bearer, name: "authorization", value: "fixture-0"}],
            idempotency_key: Ash.UUID.generate()
          },
          actor: manager
        )

      if attached do
        assert {:ok, _} =
                 Galileo.attach_integration(%{name: name, vm_id: fixture.vm.id}, actor: manager)
      end

      {token, wire} = authority(fixture, name)
      assert {:ok, _} = Authorizations.authorize(token, wire)
      assert {:ok, _} = Authorizations.renew(token, wire)
      assert {:ok, _} = Galileo.show_integration(%{name: name}, actor: manager)
      assert {:ok, _} = PeerTokens.verify(PeerTokens.mint(fixture.vm.id, integration.id, name))

      pending_token =
        if peer do
          {:ok, %{"peer" => %{"token" => pending}}} = Authorizations.authorize(token, wire)
          pending
        else
          PeerTokens.mint(fixture.vm.id, integration.id, name)
        end

      {:ok, :ok} = Ledger.transaction(fn -> Ledger.archive!(team, :archive) end, manager)
      before = snapshot(integration.id)

      for sequence <- 2..(attempts + 1) do
        fresh_report(fixture, sequence)
        assert {:error, :unauthorized} = Authorizations.authorize(token, wire)
        assert {:error, :unauthorized} = Authorizations.renew(token, wire)
        assert {:error, error} = Galileo.show_integration(%{name: name}, actor: manager)
        assert Exception.message(error) =~ "forbidden"
        assert {:ok, []} = Galileo.list_integrations(%{}, actor: manager)
        assert {:error, :invalid_peer_token} = PeerTokens.verify(pending_token)
        assert snapshot(integration.id) == before
      end
    end
  end

  # @cc [owner:ghuntley,label:verification] galileo-renewal-independent-history
  # Generated histories MUST mutate actual public membership, attachment and
  # configuration actions. The expected renewal decision MUST derive from the
  # test's operation model, not the implementation's authority predicates. Each
  # renewal MUST leave credentials, token rows and configuration receipts intact.
  # Synthetic execution reports establish application admission only.
  property "renewal tracks combined membership, attachment and ownership histories" do
    check all(
            tail <-
              list_of(member_of([:join, :leave, :attach, :detach, :team, :personal]),
                max_length: 15
              ),
            max_runs: 20
          ) do
      fixture = fresh_fixture()
      manager = Marshall.ComputeFixtures.user()

      {:ok, team} =
        Marshall.Teams.create_team(
          %{name: "renew-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
          actor: manager
        )

      name = "renew-" <> binary_part(Ash.UUID.generate(), 0, 12)
      {:ok, integration} = configure(name, manager, team.id, 0)
      {token, wire} = authority(fixture, name)

      operations =
        [:join, :attach, :leave, :detach, :join, :personal, :attach, :team, :detach, :leave] ++
          tail

      Enum.reduce(
        Enum.with_index(operations, 2),
        %{member: false, attached: false, team: true},
        fn {operation, sequence}, state ->
          state = apply_operation(operation, state, fixture, manager, team.id, name, sequence)
          fresh_report(fixture, sequence)
          expected = state.attached or (state.team and state.member)
          before = snapshot(integration.id)
          assert_renewal(Authorizations.renew(token, wire), expected)
          assert snapshot(integration.id) == before
          authorization = Authorizations.authorize(token, wire)
          assert match?({:ok, _}, authorization) == expected
          if not expected, do: assert(authorization == {:error, :unauthorized})
          state
        end
      )

      assert {:ok, _} = Galileo.remove_integration(%{name: name}, actor: manager)
      before = snapshot(integration.id)
      assert {:error, :unauthorized} = Authorizations.renew(token, wire)
      assert snapshot(integration.id) == before
    end
  end

  # @cc [owner:ghuntley,label:verification] galileo-renewal-no-new-provenance
  # Successful peer admission MUST mint one digest-backed token. Repeated renewal
  # after direct/peer reconfiguration MUST return exactly TTL/version without
  # minting, consuming, replacing or refreshing that token. Removal MUST refuse
  # renewal and token consumption. This does not assert network cancellation.
  property "renewals never reissue peer provenance or credentials after configuration changes" do
    check all(modes <- list_of(boolean(), min_length: 3, max_length: 10), max_runs: 15) do
      fixture = fresh_fixture()
      name = "peer-" <> binary_part(Ash.UUID.generate(), 0, 12)
      {:ok, integration} = configure_peer(name, fixture, true, 0)

      assert {:ok, _} =
               Galileo.attach_integration(%{name: name, vm_id: fixture.vm.id},
                 actor: fixture.owner
               )

      {token, wire} = authority(fixture, name)
      assert {:ok, %{"peer" => %{"token" => peer_token}}} = Authorizations.authorize(token, wire)
      assert [[digest]] = token_digests(integration.id)
      assert digest == :crypto.hash(:sha256, peer_token)

      for {peer, sequence} <- Enum.with_index(modes, 2) do
        assert {:ok, current} = configure_peer(name, fixture, peer, sequence)
        assert current.id == integration.id
        fresh_report(fixture, sequence)
        before = snapshot(integration.id)
        for _ <- 1..3, do: assert_renewal(Authorizations.renew(token, wire), true)
        assert snapshot(integration.id) == before
        assert token_digests(integration.id) == [[digest]]
      end

      assert {:ok, _} = Galileo.remove_integration(%{name: name}, actor: fixture.owner)
      assert {:error, :unauthorized} = Authorizations.renew(token, wire)
      assert {:error, :invalid_peer_token} = PeerTokens.verify(peer_token)
    end
  end

  @spec apply_operation(
          operation(),
          model(),
          fixture(),
          Marshall.Accounts.User.t(),
          String.t(),
          String.t(),
          pos_integer()
        ) :: model()
  defp apply_operation(operation, state, fixture, manager, team_id, name, sequence) do
    case operation do
      membership when membership in [:join, :leave] ->
        {:ok, _} =
          Marshall.Teams.set_team_member(
            %{
              team_id: team_id,
              email: to_string(fixture.owner.email),
              role: if(membership == :join, do: :member, else: :removed),
              idempotency_key: Ash.UUID.generate()
            },
            actor: manager
          )

        %{state | member: membership == :join}

      :attach ->
        {:ok, _} = Galileo.attach_integration(%{name: name, vm_id: fixture.vm.id}, actor: manager)
        %{state | attached: true}

      :detach ->
        {:ok, _} = Galileo.detach_integration(%{name: name, vm_id: fixture.vm.id}, actor: manager)
        %{state | attached: false}

      ownership when ownership in [:team, :personal] ->
        {:ok, _} = configure(name, manager, if(ownership == :team, do: team_id), sequence)
        %{state | team: ownership == :team}
    end
  end

  @spec configure(String.t(), Marshall.Accounts.User.t(), String.t() | nil, non_neg_integer()) ::
          {:ok, Integration.t()} | {:error, term()}
  defp configure(name, owner, team_id, sequence) do
    Galileo.configure_integration(
      %{
        name: name,
        target: "https://v#{sequence}.example.test",
        headers: [%{kind: :bearer, name: "authorization", value: "fixture-#{sequence}"}],
        peer: false,
        team_id: team_id,
        idempotency_key: Ash.UUID.generate()
      },
      actor: owner
    )
  end

  @spec configure_peer(String.t(), fixture(), boolean(), non_neg_integer()) ::
          {:ok, Integration.t()} | {:error, term()}
  defp configure_peer(name, fixture, peer, sequence) do
    Galileo.configure_integration(
      %{
        name: name,
        target: if(peer, do: nil, else: "https://v#{sequence}.example.test"),
        headers: [%{kind: :bearer, name: "authorization", value: "fixture-#{sequence}"}],
        peer: peer,
        peer_vm_id: if(peer, do: fixture.vm.id),
        idempotency_key: Ash.UUID.generate()
      },
      actor: fixture.owner
    )
  end

  @spec authority(fixture(), String.t()) :: {String.t(), wire()}
  defp authority(fixture, name) do
    {:ok, credential} = Credentials.rotate(fixture.vm.host_id, 3600)

    binding = %{
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch
    }

    assert {:ok, _} = OverallsProtocol.PrivateServices.binding(binding)
    assert OverallsProtocol.Integration.name?(name)
    {credential.id <> "." <> credential.secret, %{"name" => name, "binding" => binding}}
  end

  @spec assert_renewal(term(), boolean()) :: :ok
  defp assert_renewal(result, true) do
    assert result == {:ok, %{"version" => 1, "ttl" => 2000}}
    :ok
  end

  defp assert_renewal(result, false) do
    assert result == {:error, :unauthorized}
    :ok
  end

  @spec snapshot(String.t()) :: [term()]
  defp snapshot(id) do
    [
      Ledger.history!(Integration, id: id),
      Ledger.read!(Galileo.IntegrationHeader, integration_id: id),
      Ledger.read!(Galileo.Attachment, integration_id: id),
      Ledger.read!(Marshall.Accounts.AdminEvent, target_id: id),
      Ledger.read!(Galileo.PeerToken, integration_id: id),
      Ledger.read!(Galileo.Credential)
    ]
  end

  @spec token_digests(String.t()) :: [[binary()]]
  defp token_digests(id),
    do:
      Marshall.Repo.query!(
        "SELECT digest FROM galileo_peer_tokens WHERE integration_id=$1",
        [Ecto.UUID.dump!(id)],
        log: false
      ).rows

  @spec fresh_report(fixture(), pos_integer()) :: :ok
  defp fresh_report(fixture, sequence) do
    assert {:ok, :ok} =
             HostReports.ingest(fixture.host.id, fixture.connection.epoch, %{
               fixture.report
               | sequence: sequence,
                 sampled_at: Ledger.now()
             })

    :ok
  end

  @spec fresh_fixture() :: fixture()
  defp fresh_fixture do
    for host <- Ledger.read!(Marshall.Compute.Host),
        do: Ledger.update!(host, :configure, %{enabled: false})

    source = Marshall.TerminalFixtures.terminal_fixture()

    %{
      host: source.host,
      owner: source.owner,
      vm: source.vm,
      connection: source.connection,
      report: source.report
    }
  end
end
