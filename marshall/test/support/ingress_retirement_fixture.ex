defmodule Marshall.IngressRetirementFixture do
  @moduledoc "Committed Audi gateway session fixtures for renewal-versus-retirement schedules."
  alias Marshall.Accounts.{User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.{ComputeFixtures, CredentialRetirementFixture, GuestIdentityFixture}
  alias Marshall.Ingress
  alias Marshall.Ingress.{Endpoint, Session, Token}
  alias Marshall.SSH
  require Ash.Query

  @type fixture :: %{
          roster: GuestIdentityFixture.roster_fixture(),
          owner: User.t(),
          member: User.t(),
          admin: User.t(),
          gateway_token: String.t(),
          public_key: String.t(),
          label: String.t()
        }

  # @cc [owner:ghuntley,label:verification] ingress-retirement-committed-fixture
  # Every row MUST commit before peers act; only this fixture's own rows may be
  # cleaned up, and teardown runs only after gated production calls drain.
  @spec setup!() :: fixture()
  def setup! do
    roster = GuestIdentityFixture.single_roster_fixture!()
    member = ComputeFixtures.user()
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

    public_key =
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

    {:ok, _key} = SSH.add_key(%{public_key: public_key}, actor: member)
    :ok = GuestIdentityFixture.share!(roster, member)
    {gateway_token, _} = Token.issue()

    {:ok, _service} =
      Ingress.configure_service(
        %{
          name: "ingress-retire-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: roster.host_id,
          token: gateway_token
        },
        actor: SystemActor.compute()
      )

    [endpoint] = Ledger.read!(Endpoint, vm_id: roster.vm_id)

    %{
      roster: roster,
      owner: roster.owner,
      member: member,
      admin: admin,
      gateway_token: gateway_token,
      public_key: public_key,
      label: endpoint.label
    }
  end

  @spec open(fixture()) :: {:ok, map()} | {:error, term()}
  def open(fixture),
    do:
      Ingress.open_ssh(
        %{
          service_token: fixture.gateway_token,
          public_key: fixture.public_key,
          label: fixture.label
        },
        actor: SystemActor.compute()
      )

  @spec renew(fixture(), String.t()) :: {:ok, map()} | {:error, term()}
  def renew(fixture, ticket),
    do:
      Ingress.renew_ssh(
        %{service_token: fixture.gateway_token, session_token: ticket},
        actor: SystemActor.compute()
      )

  @spec retire(User.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def retire(admin, account), do: CredentialRetirementFixture.retire(admin, account)

  @spec complete(String.t()) :: {:ok, map()} | {:error, term()}
  def complete(deletion_id), do: CredentialRetirementFixture.complete(deletion_id)

  @spec install_gate(String.t(), pos_integer()) :: :ok
  def install_gate(account_id, gate),
    do: CredentialRetirementFixture.install_gate(:retirement, account_id, gate)

  @spec remove_gate(String.t()) :: :ok
  def remove_gate(account_id),
    do: CredentialRetirementFixture.remove_gate(:retirement, account_id)

  @spec snapshot(fixture()) :: %{
          retired: boolean(),
          sessions: [{String.t(), boolean(), boolean()}],
          grants: [String.t()],
          keys: [String.t()],
          deletions: [{String.t(), boolean()}]
        }
  def snapshot(fixture) do
    %{
      retired: Marshall.Accounts.Security.current(fixture.member.id).deleted_at != nil,
      sessions:
        Session
        |> Ash.Query.filter(vm_id == ^fixture.roster.vm_id)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.map(
          &{&1.id, &1.closed_at != nil, DateTime.compare(&1.expires_at, Ledger.now()) == :gt}
        )
        |> Enum.sort(),
      grants:
        Ledger.read!(Marshall.Access.Grant,
          vm_id: fixture.roster.vm_id,
          user_id: fixture.member.id
        )
        |> Enum.map(& &1.id)
        |> Enum.sort(),
      keys: Ledger.read!(SSH.Key, user_id: fixture.member.id) |> Enum.map(& &1.id) |> Enum.sort(),
      deletions:
        Ledger.read!(UserDeletion, user_id: fixture.member.id)
        |> Enum.map(&{&1.id, &1.completed_at != nil})
        |> Enum.sort()
    }
  end

  # @cc [owner:ghuntley,label:verification] ingress-retirement-fixture-cleanup
  # Teardown MUST remove this fixture's sessions, gateway service, keys, grants,
  # compute rows and users in dependency order, including audit versions.
  @spec cleanup!(fixture()) :: :ok
  def cleanup!(fixture) do
    vm = Ecto.UUID.dump!(fixture.roster.vm_id)

    query(
      "DELETE FROM ingress_sessions_versions WHERE version_source_id IN (SELECT id FROM ingress_sessions WHERE vm_id=$1)",
      [vm]
    )

    query("DELETE FROM ingress_sessions WHERE vm_id=$1", [vm])

    query(
      "DELETE FROM ingress_services_versions WHERE version_source_id IN (SELECT id FROM ingress_services WHERE host_id=$1)",
      [Ecto.UUID.dump!(fixture.roster.host_id)]
    )

    query(
      "DELETE FROM ingress_services WHERE host_id=$1",
      [Ecto.UUID.dump!(fixture.roster.host_id)]
    )

    member = Ecto.UUID.dump!(fixture.member.id)

    query(
      "DELETE FROM ssh_keys_versions WHERE version_source_id IN (SELECT id FROM ssh_keys WHERE user_id=$1)",
      [member]
    )

    query("DELETE FROM ssh_keys WHERE user_id=$1", [member])

    GuestIdentityFixture.cleanup_rosters([fixture.roster])
    GuestIdentityFixture.cleanup_users([fixture.member, fixture.admin])
    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, sql, params, log: false)
end
