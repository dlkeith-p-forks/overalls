defmodule Marshall.GalileoPeerFixture do
  @moduledoc "Committed admission identities and scoped teardown for peer provenance races."
  alias Marshall.Galileo
  alias Marshall.Repo
  alias Marshall.CommittedFixtureCleanup, as: Cleanup

  @type t :: %{
          host: Marshall.Compute.Host.t(),
          owner: Marshall.Accounts.User.t(),
          vm: Marshall.Compute.VirtualMachine.t(),
          integration: Galileo.Integration.t(),
          created_image_ids: [String.t()]
        }

  # @cc [owner:ghuntley,label:verification] peer-fixture-provenance-only
  # Setup MUST create committed source identities through real provisioning and
  # integration actions. A pending source is sufficient for token consumption;
  # this fixture MUST NOT claim request admission, TLS or native execution.
  @spec create() :: t()
  def create do
    images_before = Cleanup.fixture_image_ids()
    host = Marshall.ComputeFixtures.host_fixture()
    created_image_ids = Cleanup.fixture_image_ids() -- images_before
    owner = Marshall.ComputeFixtures.user()
    {:ok, vm} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: owner)

    {:ok, integration} =
      Galileo.configure_integration(
        %{
          name: "peer-race-" <> binary_part(Ash.UUID.generate(), 0, 12),
          target: "https://fixture.example.test",
          headers: [],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    %{
      host: host.host,
      owner: owner,
      vm: vm,
      integration: integration,
      created_image_ids: created_image_ids
    }
  end

  @spec token_count(String.t()) :: non_neg_integer()
  def token_count(id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM galileo_peer_tokens WHERE integration_id=$1",
        [Ecto.UUID.dump!(id)],
        log: false
      )

    count
  end

  # @cc [owner:ghuntley,label:verification] peer-fixture-scoped-cleanup
  # Teardown MUST delete only this fixture's IDs and drain callers first. Shared
  # image rows may be removed only when created by this fixture and after their
  # final VM reference disappears. Prior unreferenced catalog rows MUST survive.
  @spec cleanup(t()) :: :ok
  def cleanup(fixture) do
    params = [Ecto.UUID.dump!(fixture.integration.id)]

    for statement <- [
          "DELETE FROM galileo_peer_tokens WHERE integration_id=$1",
          "DELETE FROM account_admin_events WHERE target_id=$1",
          "DELETE FROM galileo_integrations_versions WHERE version_source_id=$1",
          "DELETE FROM galileo_integrations WHERE id=$1"
        ],
        do: Repo.query!(statement, params, log: false)

    {:ok, _} = Cleanup.cleanup_compute(fixture.host.id, fixture.owner.id)
    Cleanup.images!(fixture.created_image_ids)
    :ok
  end
end
