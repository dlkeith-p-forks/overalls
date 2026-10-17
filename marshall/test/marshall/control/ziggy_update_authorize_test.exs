defmodule Marshall.Control.ZiggyUpdateAuthorizeTest do
  @moduledoc """
  Socket refusals for Ziggy's `update_authorize` op.

  Every denial class asserted here routes through
  `Marshall.Control.Services.Ziggy` into
  `Marshall.Inference.Requests.authorize_update/2`; the answer MUST be a
  closed refusal name that carries no artifact identifiers, and authority
  refusals MUST surface as `unauthorized` rather than an outage. A socket bound
  before a credential change is re-authenticated by every request.
  """
  use Marshall.DataCase, async: false
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Inference.Credentials

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
  test "Customer update authorization is a closed 403 with a closed body", c do
    response = update_authorize(c.ziggy_token, c.binding)
    assert response == {:error, "unauthorized"}
  end

  test "rotated, expired and cross-host credentials all surface the same closed 403", c do
    # Baseline: this live credential binding is eligible; the refusal below is
    # the unpublished-release class (no release exists in the test MIX_ENV).
    baseline = update_authorize(c.ziggy_token, c.binding)
    assert baseline == {:error, "invalid_request"}

    {:ok, _successor} = Credentials.rotate(c.vm.host_id, 3600)
    rotated = update_authorize(c.ziggy_token, c.binding)

    # Expired credential on another enrolled inference host.
    other = Marshall.ComputeFixtures.host_fixture()
    {:ok, other_key} = Credentials.rotate(other.host.id, 3600)

    %Postgrex.Result{num_rows: 1} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE inference_credentials SET expires_at = now() - interval '1 hour' WHERE id = $1",
        [Ecto.UUID.dump!(other_key.id)]
      )

    expired =
      update_authorize(other_key.id <> "." <> other_key.secret, %{
        "host_id" => other.host.id,
        "vm_id" => Ash.UUID.generate(),
        "placement_id" => Ash.UUID.generate(),
        "execution_epoch" => 1
      })

    # This host's live credential claiming the other host.
    cross_host =
      update_authorize(c.ziggy_token, %{
        "host_id" => other.host.id,
        "vm_id" => Ash.UUID.generate(),
        "placement_id" => Ash.UUID.generate(),
        "execution_epoch" => 1
      })

    for response <- [rotated, expired, cross_host] do
      assert response == {:error, "unauthorized"}
    end
  end

  test "stale pre-relocation placement and epoch surface as a closed 403", c do
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

    response = update_authorize(c.ziggy_token, c.binding)
    assert response == {:error, "unauthorized"}
  end

  test "extra or missing binding fields are rejected before authority checks", c do
    for body <- [
          Map.put(c.binding, "generation", 1),
          Map.put(c.binding, "digest", String.duplicate("0", 64)),
          Map.delete(c.binding, "execution_epoch"),
          %{},
          %{"host_id" => "not-a-uuid"}
        ] do
      response = update_authorize(c.ziggy_token, body)
      assert response == {:error, "invalid_request"}
    end
  end

  test "an eligible binding without a published release is closed and not a server error", c do
    # Eligibility is proven transactionally; the release manifest is only ever
    # published by the NixOS service, so the test environment observes the
    # distinct unavailable class rather than an artifact. What matters on the
    # wire: never a 5xx, never a body containing digest or size.
    assert update_authorize(c.ziggy_token, c.binding) == {:error, "invalid_request"}
  end

  test "missing or malformed credentials never reach dispatch" do
    alias Marshall.Control.Services.Ziggy
    assert Ziggy.authenticate("too-short") == :refused
    assert Ziggy.authenticate(String.duplicate("k", 80)) == :refused
  end

  @spec update_authorize(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  defp update_authorize(token, body) do
    Marshall.Control.Services.Ziggy.handle_request(
      "ziggy.update_authorize",
      Map.put(body, "version", 2),
      %{token: token}
    )
  end
end
