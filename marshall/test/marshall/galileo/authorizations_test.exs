defmodule Marshall.Galileo.AuthorizationsTest do
  use Marshall.DataCase, async: false
  import ExUnit.CaptureLog
  alias Marshall.Galileo
  alias Marshall.Galileo.Credentials

  setup context do
    fixture =
      Marshall.TerminalFixtures.terminal_fixture(%{
        profile: Map.get(context, :profile, :standard)
      })

    {:ok, key} = Credentials.rotate(fixture.vm.host_id, 3600)
    token = key.id <> "." <> key.secret

    binding = %{
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch
    }

    Map.merge(fixture, %{galileo_token: token, binding: binding})
  end

  defp authorize(c, name, overrides \\ %{}) do
    Marshall.Galileo.Authorizations.authorize(
      c.galileo_token,
      Map.merge(%{"binding" => c.binding, "name" => name}, overrides)
    )
  end

  test "explicitly attached owner machines reach their integration with injected credentials",
       c do
    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "esample",
          target: "https://api.example.test",
          strip_prefix: "/api/v3",
          headers: [
            %{kind: :bearer, name: "authorization", value: "sk-live"},
            %{kind: :static, name: "x-team", value: "platform"}
          ],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    assert {:error, :unauthorized} = authorize(c, "esample")

    assert {:ok, _} =
             Galileo.attach_integration(%{name: "esample", vm_id: c.vm.id}, actor: c.owner)

    assert {:ok, authorization} = authorize(c, "esample")
    assert authorization["target"] == "https://api.example.test"
    assert authorization["strip_prefix"] == "/api/v3"
    assert authorization["ttl"] == 2000

    assert ["authorization", "Bearer sk-live"] in authorization["headers"]
    assert ["x-team", "platform"] in authorization["headers"]
    assert length(authorization["headers"]) == 2
    refute Map.has_key?(authorization, "peer")
    assert Jason.decode!(Jason.encode!(authorization)) == authorization
  end

  test "basic credentials compute the authorization header", c do
    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "basicapi",
          target: "https://api.example.test",
          headers: [%{kind: :basic, name: "authorization", value: "alice:hunter2"}],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    assert {:ok, _} =
             Galileo.attach_integration(%{name: "basicapi", vm_id: c.vm.id}, actor: c.owner)

    assert {:ok, authorization} = authorize(c, "basicapi")
    expected = "Basic " <> Base.encode64("alice:hunter2")
    assert authorization["headers"] == [["authorization", expected]]
  end

  test "unattached machines and unknown names deny", c do
    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "private",
          target: "https://api.example.test",
          headers: [],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: Marshall.ComputeFixtures.user()
      )

    assert {:error, :unauthorized} = authorize(c, "private")
    assert {:error, :unauthorized} = authorize(c, "missing")
  end

  test "attachments admit otherwise unowned machines", c do
    stranger = Marshall.ComputeFixtures.user()

    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "shared",
          target: "https://api.example.test",
          headers: [],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: stranger
      )

    assert {:error, :unauthorized} = authorize(c, "shared")

    assert {:ok, _} =
             Galileo.attach_integration(%{name: "shared", vm_id: c.vm.id}, actor: stranger)

    assert {:ok, _} = authorize(c, "shared")
  end

  test "renewal returns only a TTL and fences stopped executions", c do
    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "renewable",
          target: "https://api.example.test",
          headers: [%{kind: :bearer, name: "authorization", value: "secret"}],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    wire = %{"binding" => c.binding, "name" => "renewable"}

    assert {:ok, _} =
             Galileo.attach_integration(%{name: "renewable", vm_id: c.vm.id}, actor: c.owner)

    assert {:ok, %{"version" => 1, "ttl" => 2000}} =
             Marshall.Galileo.Authorizations.renew(c.galileo_token, wire)

    Marshall.Compute.Ledger.intent!(c.vm, %{desired_state: :stopped})

    assert {:error, :unauthorized} =
             Marshall.Galileo.Authorizations.renew(c.galileo_token, wire)
  end

  test "attachments cannot bypass integration owner liveness", c do
    stranger = Marshall.ComputeFixtures.user()

    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "retired-owner",
          target: "https://api.example.test",
          headers: [],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: stranger
      )

    assert {:ok, _} =
             Galileo.attach_integration(%{name: "retired-owner", vm_id: c.vm.id}, actor: stranger)

    Marshall.Compute.Ledger.update!(stranger, :security_state, %{
      deleted_at: Marshall.Compute.Ledger.now()
    })

    assert {:error, :unauthorized} = authorize(c, "retired-owner")
  end

  test "team-owned integrations reach member machines automatically", c do
    {:ok, team} =
      Marshall.Teams.create_team(
        %{
          name: "platform-" <> (Ash.UUID.generate() |> binary_part(0, 8)),
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "teamapi",
          target: "https://api.example.test",
          headers: [],
          peer: false,
          team_id: team.id,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    assert {:ok, _} = authorize(c, "teamapi")
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-team-liveness-membership-pin
  # A live team's automatic integration authority requires current membership.
  # Retiring the configuring user MUST NOT disable a live member's machine;
  # archived-team refusal is verified separately by renewal_history_test.
  test "team-owned integrations bind authority to membership, not the configuring user", c do
    manager = Marshall.ComputeFixtures.user()

    {:ok, team} =
      Marshall.Teams.create_team(
        %{
          name: "liveness-" <> (Ash.UUID.generate() |> binary_part(0, 8)),
          idempotency_key: Ash.UUID.generate()
        },
        actor: manager
      )

    {:ok, _} =
      Galileo.configure_integration(
        %{
          name: "teamlive",
          target: "https://api.example.test",
          headers: [],
          peer: false,
          team_id: team.id,
          idempotency_key: Ash.UUID.generate()
        },
        actor: manager
      )

    {:ok, _} =
      Marshall.Teams.set_team_member(
        %{
          team_id: team.id,
          email: to_string(c.owner.email),
          role: :member,
          idempotency_key: Ash.UUID.generate()
        },
        actor: manager
      )

    assert {:ok, _} = authorize(c, "teamlive")

    Marshall.Compute.Ledger.update!(manager, :security_state, %{
      deleted_at: Marshall.Compute.Ledger.now()
    })

    assert {:ok, _} = authorize(c, "teamlive")

    assert {:ok, %{"version" => 1, "ttl" => 2000}} =
             Marshall.Galileo.Authorizations.renew(c.galileo_token, %{
               "binding" => c.binding,
               "name" => "teamlive"
             })
  end

  @tag profile: :customer
  test "customer machines never authorize", c do
    assert {:error, :unauthorized} = authorize(c, "any")
  end

  test "forged bindings and foreign host credentials deny", c do
    assert {:error, :invalid_request} =
             Marshall.Galileo.Authorizations.authorize(c.galileo_token, %{
               "binding" => %{"host_id" => "nope"},
               "name" => "esample"
             })

    other = Marshall.ComputeFixtures.host_fixture()
    {:ok, foreign} = Credentials.rotate(other.host.id, 3600)

    assert {:error, :unauthorized} =
             Marshall.Galileo.Authorizations.authorize(foreign.id <> "." <> foreign.secret, %{
               "binding" => c.binding,
               "name" => "esample"
             })
  end

  test "refused authorizations emit closed denial reasons", c do
    old_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      capture_log([metadata: [:event, :reason]], fn ->
        assert {:error, :invalid_request} =
                 Marshall.Galileo.Authorizations.authorize(c.galileo_token, %{
                   "name" => "esample"
                 })
      end)

    assert logs =~ "event=galileo.authorization_denied"
    assert logs =~ "reason=invalid_request"

    denial_logs =
      capture_log([metadata: [:event, :reason]], fn ->
        assert {:error, :unauthorized} = authorize(c, "esample")
      end)

    assert denial_logs =~ "event=galileo.authorization_denied"
    assert denial_logs =~ "reason=unauthorized"
    refute denial_logs =~ c.galileo_token
  end
end
