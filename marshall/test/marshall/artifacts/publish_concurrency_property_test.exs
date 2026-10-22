defmodule Marshall.Artifacts.PublishConcurrencyPropertyTest do
  # @cc [owner:ghuntley,label:verification;concurrency] artifact-publish-single-winner
  # Concurrent publishes from the same base version MUST produce exactly one
  # new version; every loser MUST be refused as stale with the winner's version.
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Artifacts.{Artifact, Publisher, Version}
  alias Marshall.Compute.Ledger

  @tag :hegel_case_sandbox
  property "concurrent publishes from one base have exactly one winner" do
    Marshall.DataCase.isolate_property_case()
    writers = draw("writers", integer(2, 6))
    owner = Marshall.PasskeyFixture.user(false)

    {:ok, %{artifact: artifact}} =
      Publisher.publish(owner, %{
        artifact_id: nil,
        base_version: 0,
        page: {:content, "base"},
        via: :web
      })

    results =
      1..writers
      |> Enum.map(fn n ->
        Task.async(fn ->
          Publisher.publish(owner, %{
            artifact_id: artifact.id,
            base_version: 1,
            page: {:content, "writer #{n}"},
            via: :agent
          })
        end)
      end)
      |> Task.await_many(30_000)

    {wins, losses} = Enum.split_with(results, &match?({:ok, _}, &1))
    assert [{:ok, %{version: %Version{number: 2}}}] = wins
    assert Enum.all?(losses, &(&1 == {:error, :stale_base_version, %{current_version: 2}}))

    [current] = Ledger.read!(Artifact, id: artifact.id)
    assert current.current_version == 2
    assert length(Ledger.read!(Version, artifact_id: artifact.id)) == 2
  end
end
