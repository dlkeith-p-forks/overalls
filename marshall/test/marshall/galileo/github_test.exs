defmodule Marshall.Galileo.GitHubTest do
  use Marshall.DataCase, async: false
  alias Marshall.Compute.Ledger
  alias Marshall.Galileo.{Credentials, GitHub}
  alias Marshall.GitHub.{Connection, Provider}
  alias OverallsProtocol.GitHub, as: Wire
  @moduletag capture_log: true

  setup do
    settings = [
      github_client_id: "synthetic-client",
      github_client_secret_file: "/unused-test-path",
      github_redirect_uri: "https://example.test/auth/github-com/callback",
      github_provider: Marshall.GitHubTestProvider
    ]

    originals = Map.new(settings, fn {key, _} -> {key, Application.fetch_env(:marshall, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:marshall, key, value) end)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:marshall, key, value)
        {key, :error} -> Application.delete_env(:marshall, key)
      end)
    end)

    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    {:ok, key} = Credentials.rotate(fixture.vm.host_id, 3600)

    binding = %{
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch
    }

    Map.merge(fixture, %{galileo_token: key.id <> "." <> key.secret, binding: binding})
  end

  test "the built-in automatically selects the VM owner without generic attachment", context do
    connection = connected!(context.owner.id)
    assert {:ok, wire} = GitHub.authorize(context.galileo_token, input(context.binding))
    assert {:ok, authorization} = Wire.authorization(wire)
    assert authorization.target == "https://api.github.com"
    assert authorization.headers == [{"authorization", "Bearer synthetic-owner-token"}]
    assert authorization.lease.connection_id == connection.id

    assert {:ok, %{"version" => 1, "ttl" => 2000}} =
             GitHub.renew(context.galileo_token, %{
               "binding" => context.binding,
               "lease" => wire["lease"]
             })

    assert {:ok, %{"closed" => true}} =
             GitHub.close(context.galileo_token, %{
               "binding" => context.binding,
               "lease" => wire["lease"]
             })

    assert {:error, :unauthorized} =
             GitHub.renew(context.galileo_token, %{
               "binding" => context.binding,
               "lease" => wire["lease"]
             })
  end

  test "disconnect and machine detach preserve anonymous public admission", context do
    assert {:ok, %{"headers" => [], "lease" => %{"kind" => "anonymous"}}} =
             GitHub.authorize(context.galileo_token, input(context.binding))

    connected!(context.owner.id)
    assert {:ok, wire} = GitHub.authorize(context.galileo_token, input(context.binding))
    {actor, _} = Marshall.PasskeyFixture.login(context.owner)
    assert {:ok, _} = Marshall.GitHub.set_excluded(actor, context.vm.id, true)
    assert {:ok, anonymous} = GitHub.authorize(context.galileo_token, input(context.binding))
    assert anonymous["headers"] == []
    assert anonymous["lease"] == %{"kind" => "anonymous"}

    assert {:error, :unauthorized} =
             GitHub.renew(context.galileo_token, %{
               "binding" => context.binding,
               "lease" => wire["lease"]
             })

    assert {:ok, %{"ttl" => 2000}} =
             GitHub.renew(context.galileo_token, %{
               "binding" => context.binding,
               "lease" => anonymous["lease"]
             })
  end

  test "guest identity fields, stale execution and wrong physical bindings cannot select a token",
       context do
    connected!(context.owner.id)

    assert {:error, :invalid_request} =
             GitHub.authorize(
               context.galileo_token,
               Map.put(input(context.binding), "owner_id", context.owner.id)
             )

    for binding <- [
          Map.update!(context.binding, "execution_epoch", &(&1 + 1)),
          Map.put(context.binding, "placement_id", Ash.UUID.generate()),
          Map.put(context.binding, "host_id", Ash.UUID.generate())
        ] do
      assert {:error, :unauthorized} = GitHub.authorize(context.galileo_token, input(binding))
    end

    assert {:ok, wire} = GitHub.authorize(context.galileo_token, input(context.binding))
    forged = Map.update!(wire["lease"], "generation", &(&1 + 1))

    assert {:error, :unauthorized} =
             GitHub.renew(context.galileo_token, %{
               "binding" => context.binding,
               "lease" => forged
             })

    Ledger.intent!(context.vm, %{desired_state: :stopped})

    assert {:error, :unauthorized} =
             GitHub.authorize(context.galileo_token, input(context.binding))

    assert {:error, :unauthorized} =
             GitHub.renew(context.galileo_token, %{
               "binding" => context.binding,
               "lease" => wire["lease"]
             })
  end

  test "capability authorization never issues OAuth headers", context do
    connected!(context.owner.id)

    request = %{
      "binding" => context.binding,
      "route" => %{
        "kind" => "capability",
        "method" => "PUT",
        "path" => "/" <> String.duplicate("a", 43),
        "query" => ""
      }
    }

    assert {:ok, %{"headers" => [], "lease" => %{"kind" => "connected"}}} =
             GitHub.authorize(context.galileo_token, request)
  end

  test "Git smart HTTP uses token-as-password Basic authentication", context do
    connected!(context.owner.id)

    for kind <- ["git", "gist"] do
      request = put_in(input(context.binding), ["route", "kind"], kind)
      assert {:ok, wire} = GitHub.authorize(context.galileo_token, request)

      assert wire["headers"] == [
               [
                 "authorization",
                 "Basic " <> Base.encode64("x-access-token:synthetic-owner-token")
               ]
             ]
    end
  end

  test "generic configuration cannot occupy the built-in provider name", context do
    assert {:error, _} =
             Marshall.Galileo.configure_integration(
               %{
                 name: Wire.name(),
                 target: "https://attacker.invalid",
                 headers: [],
                 peer: false,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: context.owner
             )
  end

  @spec input(map()) :: map()
  defp input(binding),
    do: %{
      "binding" => binding,
      "route" => %{"kind" => "api", "method" => "GET", "path" => "/user", "query" => ""}
    }

  @spec connected!(String.t()) :: Connection.t()
  defp connected!(owner_id) do
    now = Ledger.now()
    connection = Ledger.create!(Connection, :register, %{user_id: owner_id})

    Ledger.update!(connection, :connect, %{
      github_id: System.unique_integer([:positive]),
      github_login: "synthetic-owner",
      generation: 2,
      scopes: Provider.scopes(),
      credentials: %{
        "access_token" => "synthetic-owner-token",
        "refresh_token" => "synthetic-owner-refresh"
      },
      expires_at: DateTime.add(now, 28_800, :second),
      refresh_expires_at: DateTime.add(now, 1_000_000, :second),
      refresh_due_at: DateTime.add(now, 28_200, :second)
    })
  end
end
