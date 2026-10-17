defmodule Marshall.Inference.UpdateAuthorityTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Inference.{Credentials, Requests}

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

    Map.merge(fixture, %{ziggy_key: key, ziggy_token: token, binding: binding})
  end

  @tag profile: :customer
  test "Customer profiles receive the closed refusal and no artifact identifiers", c do
    assert_closed_denial(Requests.authorize_update(c.ziggy_token, c.binding))
    assert {:error, :unauthorized} = Requests.authorize(c.ziggy_token, c.binding)
  end

  test "foreign host credentials and foreign host claims are refused identically", c do
    other = Marshall.ComputeFixtures.host_fixture()
    {:ok, other_key} = Credentials.rotate(other.host.id, 3600)
    other_token = other_key.id <> "." <> other_key.secret

    # The other host's credential cannot authorize this VM.
    assert_closed_denial(Requests.authorize_update(other_token, c.binding))

    # This host's credential cannot claim the other host, even with a
    # protocol-valid binding shape.
    assert_closed_denial(
      Requests.authorize_update(c.ziggy_token, %{
        "host_id" => other.host.id,
        "vm_id" => Ash.UUID.generate(),
        "placement_id" => Ash.UUID.generate(),
        "execution_epoch" => 1
      })
    )
  end

  test "expired credentials are refused before any artifact resolution", c do
    %Postgrex.Result{num_rows: 1} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE inference_credentials SET expires_at = now() - interval '1 hour' WHERE id = $1",
        [Ecto.UUID.dump!(c.ziggy_key.id)]
      )

    assert_closed_denial(Requests.authorize_update(c.ziggy_token, c.binding))
  end

  test "revoked credentials are refused identically to expired ones", c do
    {:ok, successor} = Credentials.rotate(c.vm.host_id, 3600)
    assert successor.id != c.ziggy_key.id
    assert_closed_denial(Requests.authorize_update(c.ziggy_token, c.binding))
  end

  test "stale placement, epoch and generation after relocation are refused", c do
    assert {:error, :unavailable} = Requests.authorize_update(c.ziggy_token, c.binding)

    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    vm = Ledger.intent!(vm, %{desired_state: :stopped})

    Ledger.update!(vm, :handoff, %{
      current_placement_id: Ash.UUID.generate(),
      execution_epoch: vm.execution_epoch + 1,
      generation: vm.generation + 1,
      desired_state: :running,
      observed_state: :running,
      outcome_sequence: 1,
      observed_at: Ledger.now()
    })

    # The pre-relocation binding no longer describes the current execution.
    assert_closed_denial(Requests.authorize_update(c.ziggy_token, c.binding))

    # The pre-relocation generation/epoch with the new placement is also closed.
    assert_closed_denial(
      Requests.authorize_update(c.ziggy_token, %{
        c.binding
        | "placement_id" => Ash.UUID.generate()
      })
    )
  end

  test "an eligible binding without a published release resolves closed as unavailable", c do
    # OVERALLS_LYRA_RELEASE is only set by the NixOS service; the test
    # environment deliberately never publishes one. Eligibility is proven
    # before release resolution, so the distinct :unavailable reason pins that
    # the transaction authenticated and authorized this exact binding.
    assert nil == System.get_env("OVERALLS_LYRA_RELEASE")
    assert {:error, :unavailable} = Requests.authorize_update(c.ziggy_token, c.binding)
  end

  property "arbitrary wire shapes never disclose artifacts and never raise", c do
    check all(
            wire <-
              map_of(
                string(:alphanumeric, max_length: 8),
                one_of([string(:alphanumeric), integer(), boolean()]),
                max_length: 6
              )
          ) do
      case Requests.authorize_update(c.ziggy_token, wire) do
        {:error, :invalid_binding} -> :ok
        {:error, :unauthorized} -> :ok
        {:ok, _} -> flunk("update authorization disclosed an artifact")
        other -> flunk("update authorization returned an unclassified result: #{inspect(other)}")
      end
    end
  end

  property "exactly-shaped bindings with mutated decisive fields never reach eligibility", c do
    mutations = [
      :foreign_host,
      :foreign_vm,
      :foreign_placement,
      :zero_epoch,
      :future_epoch
    ]

    check all(mutation <- member_of(mutations)) do
      wire =
        case mutation do
          :foreign_host -> %{c.binding | "host_id" => Ash.UUID.generate()}
          :foreign_vm -> %{c.binding | "vm_id" => Ash.UUID.generate()}
          :foreign_placement -> %{c.binding | "placement_id" => Ash.UUID.generate()}
          :zero_epoch -> %{c.binding | "execution_epoch" => 0}
          :future_epoch -> %{c.binding | "execution_epoch" => c.vm.execution_epoch + 1}
        end

      assert_closed_denial(Requests.authorize_update(c.ziggy_token, wire))
    end
  end

  # A closed denial carries a stable atom and never artifact material: no
  # digest, size or path may accompany a refusal.
  defp assert_closed_denial({:error, reason}) when is_atom(reason) do
    assert reason in [:unauthorized, :invalid_binding]
  end
end
