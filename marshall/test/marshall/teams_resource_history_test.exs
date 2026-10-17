defmodule Marshall.TeamsResourceHistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  @moduletag capture_log: true
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{HostReports, Ledger, Operation, ProvisionerControl}
  alias Marshall.Teams

  @type role :: :admin | :member | :removed

  # @cc [owner:ghuntley,label:verification] team-resource-current-role-histories
  # Generated role histories MUST invoke real membership and resource actions and
  # independently expect member VM use, admin management, removed/foreign refusal
  # and Customer owner-only access. Synthetic host outcomes establish control
  # admission only; native guest SSH remains a separate acceptance boundary.
  property "current team membership admits guest use without granting member management" do
    check all(
            profile <- member_of([:oss, :customer]),
            roles <-
              list_of(member_of([:admin, :member, :removed]), min_length: 3, max_length: 10),
            max_runs: 20
          ) do
      fixture = fresh_fixture(:standard)
      member = Marshall.ComputeFixtures.user()
      foreign = Marshall.ComputeFixtures.user()

      {:ok, team} =
        Teams.create_team(
          %{name: "resources-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
          actor: fixture.owner
        )

      {:ok, vm} =
        Marshall.Compute.provision(
          Marshall.ComputeFixtures.request(%{team_id: team.id, profile: profile, vcpu: 1}),
          actor: fixture.owner
        )

      [operation] = Ledger.read!(Operation, vm_id: vm.id)

      {:ok, _} =
        ProvisionerControl.exchange_execution(
          fixture.credential.token,
          Map.merge(fixture.connection, %{
            report: %{fixture.report | sequence: 2, sampled_at: Ledger.now()},
            acknowledgements: [],
            outcomes: [
              %{
                id: Ash.UUID.generate(),
                vm_id: vm.id,
                placement_id: vm.current_placement_id,
                execution_epoch: vm.execution_epoch,
                operation_id: operation.id,
                generation: vm.generation,
                sequence: 1,
                state: :running,
                compute_empty: false,
                disk_present: true,
                cleanup_complete: false,
                reason: :none
              }
            ]
          })
        )

      {:ok, host_key} = Marshall.Inference.Credentials.rotate(vm.host_id, 3600)

      binding = %{
        "host_id" => vm.host_id,
        "vm_id" => vm.id,
        "placement_id" => vm.current_placement_id,
        "execution_epoch" => vm.execution_epoch
      }

      {:ok, gateway, _} = gateway(vm.host_id)

      public =
        "ssh-ed25519 " <>
          Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

      {:ok, _} = Marshall.SSH.add_key(%{public_key: public}, actor: member)
      [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: vm.id)
      username = Marshall.SharingSurfacesFixture.member_name(member)

      for {role, index} <-
            Enum.with_index([:member, :admin, :member, :removed, :member] ++ roles, 3) do
        set_role(team.id, member, role, fixture.owner)
        report = %{fixture.report | sequence: index, sampled_at: Ledger.now()}
        assert {:ok, :ok} = HostReports.ingest(fixture.host.id, fixture.connection.epoch, report)
        allowed = profile != :customer and role != :removed
        before = inventory(vm.id)
        assert Marshall.Terminal.Authority.writable?(vm.id, member) == allowed
        read = Marshall.Compute.get_vm(%{vm_id: vm.id}, actor: member)
        assert match?({:ok, _}, read) == allowed
        assert {:error, _} = Marshall.Compute.get_vm(%{vm_id: vm.id}, actor: foreign)
        assert inventory(vm.id) == before

        {:ok, roster} =
          Marshall.SSH.GuestAccess.roster(
            host_key.id <> "." <> host_key.secret,
            Marshall.TerminalFixtures.roster_binding(vm)
          )

        assert Enum.any?(roster.accounts, &(&1.username == username)) == allowed

        opening =
          Marshall.Ingress.open_ssh(
            %{service_token: gateway, public_key: public, label: endpoint.label},
            actor: SystemActor.compute()
          )

        assert match?({:ok, _}, opening) == allowed

        authorization =
          Marshall.SSH.GuestAccess.authorize(
            host_key.id <> "." <> host_key.secret,
            binding,
            public,
            username
          )

        assert match?({:ok, _}, authorization) == allowed
        before = inventory(vm.id)

        management =
          Marshall.Access.set_access(
            %{
              vm_id: vm.id,
              email: to_string(foreign.email),
              role: :revoked,
              idempotency_key: Ash.UUID.generate()
            },
            actor: member
          )

        assert match?({:ok, _}, management) == (profile != :customer and role == :admin)

        if profile == :customer or role != :admin do
          assert inventory(vm.id) == before

          for kind <- [:start, :stop, :delete] do
            assert {:error, _} =
                     Marshall.Compute.lifecycle(
                       %{vm_id: vm.id, kind: kind, idempotency_key: Ash.UUID.generate()},
                       actor: member
                     )

            assert inventory(vm.id) == before
          end
        end
      end
    end
  end

  # @cc [owner:ghuntley,label:verification] team-integration-owner-membership
  # Automatic integration access MUST track the VM owner's current membership,
  # including removal and re-addition, without explicit attachments. Customer
  # access always refuses. Configuration rights remain with team owner/admin;
  # member and removed actor attempts MUST leave integration and audit state intact.
  property "team integration access follows membership histories without attachments" do
    check all(
            profile <- member_of([:oss, :customer]),
            roles <-
              list_of(member_of([:admin, :member, :removed]), min_length: 3, max_length: 10),
            max_runs: 20
          ) do
      fixture = fresh_fixture(profile)
      founder = Marshall.ComputeFixtures.user()

      {:ok, team} =
        Teams.create_team(
          %{name: "integration-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
          actor: founder
        )

      name = "team-" <> binary_part(Ash.UUID.generate(), 0, 12)

      {:ok, integration} =
        Marshall.Galileo.configure_integration(
          %{
            name: name,
            target: "https://api.example.test",
            headers: [],
            peer: false,
            team_id: team.id,
            idempotency_key: Ash.UUID.generate()
          },
          actor: founder
        )

      {:ok, credential} = Marshall.Galileo.Credentials.rotate(fixture.vm.host_id, 3600)
      token = credential.id <> "." <> credential.secret

      wire = %{
        "name" => name,
        "binding" => %{
          "host_id" => fixture.vm.host_id,
          "vm_id" => fixture.vm.id,
          "placement_id" => fixture.vm.current_placement_id,
          "execution_epoch" => fixture.vm.execution_epoch
        }
      }

      for {role, index} <- Enum.with_index([:member, :admin, :removed, :member] ++ roles, 2) do
        set_role(team.id, fixture.owner, role, founder)

        assert {:ok, :ok} =
                 HostReports.ingest(fixture.host.id, fixture.connection.epoch, %{
                   fixture.report
                   | sequence: index,
                     sampled_at: Ledger.now()
                 })

        allowed = profile != :customer and role != :removed
        before = integration_inventory(integration.id)
        result = Marshall.Galileo.Authorizations.authorize(token, wire)
        assert match?({:ok, _}, result) == allowed
        if not allowed, do: assert(result == {:error, :unauthorized})
        assert integration_inventory(integration.id) == before
        assert Ledger.read!(Marshall.Galileo.Attachment, integration_id: integration.id) == []

        changed =
          Marshall.Galileo.configure_integration(
            %{
              name: name,
              target: "https://v" <> Integer.to_string(index) <> ".example.test",
              headers: [],
              peer: false,
              team_id: team.id,
              idempotency_key: Ash.UUID.generate()
            },
            actor: fixture.owner
          )

        assert match?({:ok, _}, changed) == (role == :admin)
        if role != :admin, do: assert(integration_inventory(integration.id) == before)
      end
    end
  end

  @spec fresh_fixture(:standard | :oss | :customer) :: map()
  defp fresh_fixture(profile) do
    # StreamData samples share this sandbox; prevent a later sample's scheduler
    # selecting an earlier sample's enrolled host and mismatching its boot proof.
    for host <- Ledger.read!(Marshall.Compute.Host),
        do: Ledger.update!(host, :configure, %{enabled: false})

    Marshall.TerminalFixtures.terminal_fixture(%{profile: profile})
  end

  @spec set_role(String.t(), User.t(), role(), User.t()) :: :ok
  defp set_role(team_id, user, role, owner) do
    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team_id,
                 email: to_string(user.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    :ok
  end

  @spec gateway(String.t()) :: {:ok, String.t(), map()}
  defp gateway(host_id) do
    {token, _} = Marshall.Ingress.Token.issue()

    {:ok, service} =
      Marshall.Ingress.configure_service(
        %{
          name: "gateway-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: host_id,
          token: token
        },
        actor: SystemActor.compute()
      )

    {:ok, token, service}
  end

  @spec inventory(String.t()) :: [term()]
  defp inventory(vm_id) do
    for resource <- [
          Marshall.Compute.VirtualMachine,
          Marshall.Compute.Operation,
          Marshall.Compute.Reservation,
          Marshall.Compute.NetworkAddress,
          Marshall.Access.Grant,
          Marshall.Access.Change
        ] do
      if resource == Marshall.Compute.VirtualMachine,
        do: rows(resource, id: vm_id),
        else: rows(resource, vm_id: vm_id)
    end
  end

  @spec rows(module(), keyword()) :: [struct()]
  defp rows(resource, filter) do
    if Ash.Resource.Info.action(resource, :history, :read),
      do: Ledger.history!(resource, filter),
      else: Ledger.read!(resource, filter)
  end

  @spec integration_inventory(String.t()) :: [term()]
  defp integration_inventory(id),
    do: [
      Ledger.history!(Marshall.Galileo.Integration, id: id),
      Ledger.read!(Marshall.Galileo.IntegrationHeader, integration_id: id),
      Ledger.read!(Marshall.Accounts.AdminEvent, target_id: id)
    ]
end
