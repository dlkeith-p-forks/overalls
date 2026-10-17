defmodule Marshall.Control.GalileoServiceTest do
  use Marshall.DataCase, async: false
  import ExUnit.CaptureLog
  alias Marshall.Galileo
  alias Marshall.Galileo.Credentials

  setup do
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

  test "a socket refusal retains a closed diagnostic reason while hiding its credential",
       context do
    logs =
      capture_log([format: "$metadata$message", metadata: [:event, :reason]], fn ->
        assert request(context.galileo_token, "authorize", %{
                 "binding" => context.binding,
                 "name" => "absent-team-integration"
               }) == {:error, "unauthorized"}
      end)

    assert logs =~ "event=galileo.authorization_denied"
    assert logs =~ "reason=unauthorized"
    refute String.contains?(logs, context.galileo_token)
  end

  test "authorize and renew return JSON-safe closed lease responses", context do
    {:ok, _integration} =
      Galileo.configure_integration(
        %{
          name: "leased-api",
          target: "https://api.example.test",
          headers: [%{kind: :bearer, name: "authorization", value: "secret"}],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: context.owner
      )

    input = %{"binding" => context.binding, "name" => "leased-api"}

    assert {:ok, _} =
             Galileo.attach_integration(%{name: "leased-api", vm_id: context.vm.id},
               actor: context.owner
             )

    assert {:ok,
            %{
              "headers" => [["authorization", "Bearer secret"]],
              "strip_prefix" => nil,
              "target" => "https://api.example.test",
              "ttl" => 2000
            }} = request(context.galileo_token, "authorize", input)

    assert request(context.galileo_token, "renew", input) ==
             {:ok, %{"ttl" => 2000, "version" => 1}}

    Marshall.Compute.Ledger.intent!(context.vm, %{desired_state: :stopped})
    assert request(context.galileo_token, "renew", input) == {:error, "unauthorized"}
  end

  @spec request(String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  defp request(token, route, input) do
    {:ok, principal} = Marshall.Control.Services.Galileo.authenticate(token)
    Marshall.Control.Services.Galileo.handle_request("galileo." <> route, input, principal)
  end
end
