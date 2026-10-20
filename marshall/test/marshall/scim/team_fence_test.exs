Code.require_file("team_fixture.exs", __DIR__)

defmodule Marshall.Scim.TeamFenceTest do
  @moduledoc "Native team mutations are fenced while SCIM is enabled and for SCIM-managed teams."
  use MarshallWeb.ConnCase, async: false
  import Marshall.PorscheSocket, only: [reply: 2]

  alias Marshall.Compute.Ledger
  alias Marshall.Scim.TeamFixture, as: Fixture
  alias Marshall.SSH
  alias Marshall.Teams
  alias Marshall.Teams.{Coordinator, ServiceOwner, Team, Transfer}

  @type account :: %{user: Marshall.Accounts.User.t(), session: String.t()}

  setup do
    {gateway, _} = SSH.Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "team-fence", token: gateway},
        actor: Marshall.Authorization.SystemActor.compute()
      )

    %{gateway: gateway}
  end

  test "SCIM-managed teams stay locked to every native mutation after SCIM is disabled", c do
    alice = account(c)
    bob = account(c)
    token = Fixture.enable!()

    {201, %{"id" => id}} =
      Fixture.request(
        token,
        :post,
        "/Groups",
        Fixture.group(Fixture.team_name(), [alice.user.id, bob.user.id])
      )

    [team] = Ledger.read!(Team, id: id)
    Fixture.disable!()
    assert Teams.creation_open?()
    refute Teams.native_mutable?(team)
    before = Fixture.memberships(id)
    owner = ServiceOwner.get!()

    # Neither a human member nor the hidden owner can mutate a managed team.
    for actor <- [alice.user, owner], role <- [:member, :admin, :removed] do
      assert {:error, _} = set_member(team, bob.user, role, actor)
    end

    assert {:error, :scim_managed} = Coordinator.offer(id, to_string(bob.user.email), owner)
    assert {:error, _} = Coordinator.offer(id, to_string(bob.user.email), alice.user)

    # A transfer row that predates the lock cannot be resolved natively either.
    transfer =
      Ash.Seed.seed!(Transfer, %{team_id: id, from_user_id: owner.id, to_user_id: bob.user.id})

    assert {:error, :scim_managed} = Coordinator.accept(transfer.id, bob.user)
    assert {:error, :scim_managed} = Coordinator.decline(transfer.id, bob.user)
    assert {:error, :scim_managed} = Coordinator.cancel(transfer.id, owner)
    assert Fixture.memberships(id) == before

    # SSH commands refuse with the permanent forbidden response.
    name = team.name
    email = to_string(bob.user.email)
    assert command(c, alice, "team member add #{name} #{email} admin", 403)
    assert command(c, alice, "team member remove #{name} #{email}", 403)
    assert command(c, alice, "team transfer offer #{name} #{email}", 403)
    assert Fixture.memberships(id) == before

    # Native team creation resumes once SCIM is disabled.
    assert {:ok, %Team{management_mode: :native}} =
             Teams.create_team(%{name: Fixture.team_name(), idempotency_key: "after"},
               actor: alice.user
             )
  end

  test "SCIM refuses native team creation, invitation and ownership changes while enabled", c do
    alice = account(c)
    bob = account(c)

    {:ok, team} =
      Teams.create_team(%{name: Fixture.team_name(), idempotency_key: "native"},
        actor: alice.user
      )

    {:ok, _} = set_member(team, bob.user, :member, alice.user)
    _token = Fixture.enable!()
    refute Teams.creation_open?()

    assert {:error, _} =
             Teams.create_team(%{name: Fixture.team_name(), idempotency_key: "blocked"},
               actor: alice.user
             )

    for role <- [:member, :admin, :removed],
        do: assert({:error, _} = set_member(team, bob.user, role, alice.user))

    assert {:error, :scim_managed} =
             Coordinator.offer(team.id, to_string(bob.user.email), alice.user)

    assert command(c, alice, "team create #{Fixture.team_name()}", 403)
    assert command(c, alice, "team member remove #{team.name} #{bob.user.email}", 403)
    assert command(c, alice, "team transfer offer #{team.name} #{bob.user.email}", 403)

    assert Fixture.memberships(team.id) ==
             Enum.sort([{alice.user.id, :owner}, {bob.user.id, :member}])

    assert Ledger.read!(Transfer, team_id: team.id) == []

    # Reads remain available: my teams and the all-teams directory.
    assert {:ok, [%{id: team_id, management_mode: :retiring}]} =
             Teams.list_teams(%{}, actor: bob.user)

    assert team_id == team.id
    assert {:ok, all} = Teams.list_all_teams(%{}, actor: Marshall.ComputeFixtures.user())
    assert %{member_count: 2} = Enum.find(all, &(&1.id == team.id))
  end

  @spec set_member(Team.t(), Marshall.Accounts.User.t(), atom(), Marshall.Accounts.User.t()) ::
          {:ok, map()} | {:error, term()}
  defp set_member(team, user, role, actor) do
    Teams.set_team_member(
      %{
        team_id: team.id,
        email: to_string(user.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end

  @spec account(map()) :: account()
  defp account(c) do
    user = Marshall.ComputeFixtures.user()

    key =
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

    assert {:ok, _} = SSH.add_key(%{public_key: key}, actor: user)

    opened =
      Marshall.PorscheSocket.request(c.gateway, "sessions", %{version: 1, public_key: key})
      |> reply(200)

    %{user: user, session: opened["session_token"]}
  end

  @spec command(map(), account(), String.t(), pos_integer()) :: true
  defp command(c, account, input, status) do
    assert {:ok, command} = OverallsProtocol.SSHCommand.parse(input)

    assert Marshall.PorscheSocket.request(c.gateway, "commands", %{
             version: 1,
             session_token: account.session,
             command: command
           })
           |> reply(status) == %{"error" => "forbidden"}
  end
end
