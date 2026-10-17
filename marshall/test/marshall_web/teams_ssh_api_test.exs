defmodule MarshallWeb.TeamsSSHAPITest do
  use MarshallWeb.ConnCase, async: false
  use ExUnitProperties
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  import Marshall.PorscheSocket, only: [reply: 2]
  alias Marshall.Teams.{Team, TeamMember, Transfer}

  @type account :: %{user: Marshall.Accounts.User.t(), session: String.t()}
  @type context :: %{gateway: String.t()}
  @type inventory :: %{String.t() => [map()]}
  @tables ~w(teams team_members team_transfers teams_versions team_members_versions team_transfers_versions account_admin_events ssh_requests)

  setup do
    {gateway, _} = SSH.Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "team-api", token: gateway},
        actor: Marshall.Authorization.SystemActor.compute()
      )

    %{gateway: gateway}
  end

  # @cc [owner:ghuntley,label:verification;security] teams-ssh-http-history
  # Every generated history MUST cross the Porsche gateway requests (served on
  # the control socket since ADR-0142) with current session authority and
  # compare full durable inventories on refusals and pinned replays. A successful
  # historical receipt MUST NOT restore membership or mutate a reused team name.
  property "HTTP histories preserve pinned receipts and permanent team refusals", c do
    check all(
            suffix <- string(?a..?z, min_length: 1, max_length: 12),
            steps <-
              list_of(member_of([:replay, :collision, :missing, :changed]),
                min_length: 1,
                max_length: 8
              ),
            max_runs: 15
          ) do
      owner = account(c)
      target = account(c)
      foreign = account(c)
      name = "ssh-" <> suffix <> "-" <> binary_part(Ash.UUID.generate(), 0, 8)
      create = "team create #{name} --request-id original --json"
      original = command(c, owner, create, 200)
      team_id = original["result"]["id"]
      assert original["status"] == "succeeded"

      assert owner.user.id ==
               Ledger.read!(TeamMember, team_id: team_id) |> hd() |> Map.fetch!(:user_id)

      assert Map.fetch!(snapshot(), "account_admin_events")
             |> Enum.count(&(&1["target_id"] == team_id)) == 2

      before_retry = snapshot()
      retried = command(c, owner, "team create #{name} --request-id safe-retry", 200)
      assert retried["result"] == original["result"]
      assert Map.delete(snapshot(), "ssh_requests") == Map.delete(before_retry, "ssh_requests")
      assert length(snapshot()["ssh_requests"]) == length(before_retry["ssh_requests"]) + 1
      unchanged(c, foreign, "team create #{name} --request-id collision", 409, "conflict")

      unchanged(
        c,
        foreign,
        "team member add #{name} #{target.user.email} member",
        403,
        "forbidden"
      )

      unchanged(c, owner, "team show absent-#{name}", 404, "not_found")
      unchanged(c, owner, "team transfer accept #{Ash.UUID.generate()}", 404, "not_found")

      command(
        c,
        owner,
        "team member add #{name} #{target.user.email} member --request-id add",
        200
      )

      declined =
        command(
          c,
          owner,
          "team transfer offer #{name} #{target.user.email} --request-id decline-offer",
          200
        )["result"]["transfer_id"]

      command(c, target, "team transfer decline #{declined} --request-id decline", 200)
      unchanged(c, target, "team transfer decline #{declined}", 409, "conflict")

      offer =
        command(
          c,
          owner,
          "team transfer offer #{name} #{target.user.email} --request-id offer",
          200
        )

      transfer = offer["result"]["transfer_id"]
      unchanged(c, owner, "team transfer offer #{name} #{target.user.email}", 409, "conflict")
      unchanged(c, foreign, "team transfer accept #{transfer}", 403, "forbidden")
      command(c, target, "team transfer accept #{transfer} --request-id accept", 200)

      assert Ledger.read!(TeamMember, team_id: team_id)
             |> Enum.map(&{&1.user_id, &1.role})
             |> Enum.sort() == Enum.sort([{owner.user.id, :admin}, {target.user.id, :owner}])

      command(
        c,
        target,
        "team member remove #{name} #{owner.user.email} --request-id remove",
        200
      )

      unchanged(c, owner, "team show #{name}", 403, "forbidden")
      unchanged(c, target, "team create #{name}", 409, "conflict")
      unchanged(c, owner, "team create #{name}", 409, "conflict")

      for step <- [:replay, :changed, :missing, :collision | steps] do
        case step do
          :replay ->
            before = snapshot()
            assert command(c, owner, create, 200) == original
            assert command(c, owner, "request show original --json", 200) == original
            assert snapshot() == before

          :changed ->
            unchanged(
              c,
              owner,
              "team create changed-#{name} --request-id original",
              409,
              "idempotency_conflict"
            )

          :missing ->
            unchanged(c, foreign, "team transfer cancel #{Ash.UUID.generate()}", 404, "not_found")

          :collision ->
            unchanged(c, foreign, "team create #{name}", 409, "conflict")
        end
      end

      # Archival has no public command. This trusted fixture transition proves
      # only that the HTTP receipt keeps its historical identity after reuse.
      [team] = Ledger.read!(Team, id: team_id)
      assert {:ok, :ok} = Ledger.transaction(fn -> Ledger.archive!(team, :archive) end)
      recovered = command(c, foreign, "team create #{name} --request-id reused", 200)
      refute recovered["result"]["id"] == team_id
      before = snapshot()
      assert command(c, owner, create, 200) == original
      assert snapshot() == before

      assert Ledger.read!(TeamMember, team_id: recovered["result"]["id"])
             |> Enum.map(& &1.user_id) == [foreign.user.id]

      command(c, owner, "team create recovered-#{name} --request-id recovery", 200)
      assert [%{state: :accepted}] = Ledger.history!(Transfer, id: transfer)
    end
  end

  test "unexpected transfer audit failure remains opaque and rolls back", c do
    owner = account(c)
    target = account(c)
    command(c, owner, "team create audit-failure", 200)
    command(c, owner, "team member add audit-failure #{target.user.email} member", 200)
    offered = command(c, owner, "team transfer offer audit-failure #{target.user.email}", 200)
    transfer = offered["result"]["transfer_id"]
    before = snapshot()

    Ecto.Adapters.SQL.query!(Marshall.Repo, """
    CREATE FUNCTION pg_temp.reject_team_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'synthetic audit storage failure'; END $$
    """)

    Ecto.Adapters.SQL.query!(Marshall.Repo, """
    CREATE TRIGGER verify008_reject_audit BEFORE INSERT ON account_admin_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_team_audit()
    """)

    assert command(c, target, "team transfer decline #{transfer}", 503) == %{
             "error" => "temporarily_unavailable"
           }

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "DROP TRIGGER verify008_reject_audit ON account_admin_events"
    )

    assert snapshot() == before
    assert command(c, target, "team transfer decline #{transfer}", 200)["status"] == "succeeded"
  end

  # @cc [owner:ghuntley,label:verification] team-name-http-validation
  # Generated malformed names MUST refuse before any durable row changes; the
  # one- and 63-character boundaries MUST remain usable. Parser length refusal
  # and domain grammar refusal MUST both stay permanent HTTP 400 responses.
  property "team name grammar and boundary refusals remain permanent", c do
    owner = account(c)

    check all(label <- string(?a..?z, min_length: 1, max_length: 20), max_runs: 20) do
      for name <- [String.upcase(label), "0" <> label, label <> "-", label <> "_"] do
        unchanged(c, owner, "team create #{name}", 400, "invalid_request")
      end

      for name <- ["", String.duplicate("a", 64)] do
        before = snapshot()

        body = %{
          version: 1,
          session_token: owner.session,
          command: %{version: 1, command: "team create", arguments: [name], options: %{}}
        }

        assert api(c, "commands", body) |> reply(400) == %{"error" => "invalid_command"}
        assert snapshot() == before
      end

      for name <- [String.first(label), String.pad_trailing(label, 63, "a")] do
        assert command(c, owner, "team create #{name}", 200)["result"]["name"] == name
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] team-resource-public-refusals
  # Exact native creation requests MUST reach real admission with an explicit
  # registered image, without relying on a configured default. Resource commands
  # MUST have explicit forbidden HTTP outcomes for
  # foreign, removed and insufficient team authority, including Customer VMs.
  # These in-process responses establish command categories, not native transport.
  test "native team resource creation and refusals use real command admission", c do
    # Pending admissions retain their full portable-bundle holds. Provide one
    # synthetic host per request without fabricating native completion.
    for _ <- 1..3 do
      Marshall.ComputeFixtures.host_fixture()
    end

    owner = account(c)
    member = account(c)
    foreign = account(c)
    team = command(c, owner, "team create native-resources", 200)["result"]["id"]
    command(c, owner, "team member add native-resources #{member.user.email} member", 200)

    refute Application.get_env(:marshall, :default_image_id)

    unchanged(
      c,
      owner,
      "new --name shared-team --team native-resources --profile oss --cpu 1 --memory 512 --disk 4 --timeout 600",
      409,
      "image_unavailable"
    )

    image = Marshall.ComputeFixtures.image_id()

    for {name, profile, actor, team_id, team_option} <- [
          {"shared-team", :oss, owner, team, " --team native-resources"},
          {"member-personal", :oss, member, nil, ""},
          {"team-customer", :customer, owner, team, " --team native-resources"}
        ] do
      request =
        "new --name #{name}#{team_option} --image #{image} --profile #{profile} --cpu 1 --memory 512 --disk 4 --timeout 600"

      receipt = command(c, actor, request, 200)
      assert receipt["status"] == "accepted"
      [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: receipt["result"]["id"])
      assert vm.owner_id == actor.user.id
      assert vm.team_id == team_id
      assert vm.profile == profile
      assert vm.image_id == image
      assert vm.vcpu == 1
      assert vm.memory_bytes == 536_870_912
      assert vm.disk_bytes == 4_294_967_296
    end

    assert command(c, member, "show shared-team", 200)["status"] == "succeeded"
    unchanged(c, member, "stop shared-team", 403, "forbidden")
    unchanged(c, foreign, "show shared-team", 403, "forbidden")
    unchanged(c, member, "show team-customer", 403, "forbidden")

    assert {:ok, _} =
             Marshall.Galileo.configure_integration(
               %{
                 name: "directapi",
                 target: "https://api.example.test",
                 headers: [],
                 peer: false,
                 team_id: team,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner.user
             )

    unchanged(c, member, "integration rm directapi", 403, "forbidden")
    unchanged(c, foreign, "integration rm directapi", 403, "forbidden")
    command(c, owner, "team member add native-resources #{member.user.email} admin", 200)
    unchanged(c, member, "stop team-customer", 403, "forbidden")
    command(c, owner, "team member remove native-resources #{member.user.email}", 200)
    unchanged(c, member, "show shared-team", 403, "forbidden")
    unchanged(c, member, "start shared-team", 403, "forbidden")
  end

  @spec account(context()) :: account()
  defp account(c) do
    user = Marshall.ComputeFixtures.user()

    key =
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

    assert {:ok, _} = SSH.add_key(%{public_key: key}, actor: user)
    opened = api(c, "sessions", %{version: 1, public_key: key}) |> reply(200)
    %{user: user, session: opened["session_token"]}
  end

  @spec command(context(), account(), String.t(), pos_integer()) :: map()
  defp command(c, account, input, status) do
    assert {:ok, command} = OverallsProtocol.SSHCommand.parse(input)

    api(c, "commands", %{version: 1, session_token: account.session, command: command})
    |> reply(status)
  end

  @spec unchanged(context(), account(), String.t(), pos_integer(), String.t()) :: :ok
  defp unchanged(c, account, input, status, reason) do
    before = snapshot()
    assert command(c, account, input, status) == %{"error" => reason}
    assert snapshot() == before
    :ok
  end

  @spec snapshot() :: inventory()
  defp snapshot do
    Map.new(@tables, fn table ->
      rows =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT row_to_json(t) FROM #{table} t ORDER BY id",
          [],
          log: false
        ).rows

      {table, Enum.map(rows, &hd/1)}
    end)
  end

  @spec api(context(), String.t(), map()) :: Marshall.PorscheSocket.reply()
  defp api(c, route, payload), do: Marshall.PorscheSocket.request(c.gateway, route, payload)
end
