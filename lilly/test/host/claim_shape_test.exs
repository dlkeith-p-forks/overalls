defmodule Lilly.Host.ClaimShapeTest do
  @moduledoc """
  A ready dataset claim is matched by its persisted storage shape. The
  production prune of clone `edd90b26` on 2026-10-13 never confirmed because
  the restarted source's start command carried a workspace source while the
  claim its stopped predecessor journaled did not; the exact-struct comparison
  refused every attempt (ADR-0162 review). This pins the shape rule at the
  claim layer without native ZFS.
  """
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Lock, Pool, ZFSDataset}
  alias Lilly.Lifecycle.Journal
  alias Lilly.VM.Spec
  @moduletag :tmp_dir

  @guid "5502938471002938"

  defp pool(path) do
    %Pool{
      id: Lilly.UUID.generate(),
      path: path,
      filesystem_id: "zfs:1:2",
      host_id: Lilly.UUID.generate(),
      storage: %{
        backend: :zfs,
        dataset: "tank/lilly",
        zpool_guid: "8473663987254177",
        dataset_guid: "1294829134928374"
      }
    }
  end

  defp spec(pool, placement) do
    {:ok, network} = Lilly.Network.Guest.new(placement, :customer, 2)

    %Spec{
      id: placement,
      image_id: "sha256:" <> String.duplicate("a", 64),
      pool_id: pool.id,
      network: network,
      vcpu: 1,
      memory_bytes: 1_073_741_824,
      disk_bytes: 4_294_967_296
    }
  end

  defp plant_ready_claim(pool, guest) do
    base = Path.join(pool.path, ".lilly-zfs")
    active = Path.join([base, "active", guest.id])
    File.mkdir_p!(active)
    for dir <- [base, Path.join(base, "active"), active], do: File.chmod!(dir, 0o700)

    File.write!(
      Path.join(base, "owner.json"),
      JSON.encode!(%{
        "host_id" => pool.host_id,
        "pool_id" => pool.id,
        "pool_path" => pool.path,
        "storage" => OverallsProtocol.Storage.encode(pool.storage)
      })
    )

    File.chmod!(Path.join(base, "owner.json"), 0o600)
    {:ok, lock} = Lock.acquire(Path.join(pool.path, "lock-hold"))

    claim = %{
      "version" => 1,
      "binding" => %{
        "host_id" => pool.host_id,
        "pool_id" => pool.id,
        "pool_path" => pool.path,
        "storage" => OverallsProtocol.Storage.encode(pool.storage),
        "spec" => Spec.encode(guest)
      },
      "nonce" => String.duplicate("cd", 16),
      "dataset_guid" => nil,
      "state" => "creating"
    }

    try do
      # The lifecycle journal admits only its own transitions: creating, bound, ready.
      :ok = Journal.write(Lilly.Lifecycle.Dataset, active, "claim.json", claim)
      bound = %{claim | "dataset_guid" => @guid, "state" => "bound"}
      :ok = Journal.write(Lilly.Lifecycle.Dataset, active, "claim.json", bound)

      :ok =
        Journal.write(Lilly.Lifecycle.Dataset, active, "claim.json", %{bound | "state" => "ready"})
    after
      :ok = Lock.release(lock)
    end
  end

  defp source_gen do
    gen all(
          namespace <-
            list_of(string(Enum.to_list(?a..?z), min_length: 1, max_length: 8),
              min_length: 1,
              max_length: 2
            ),
          repository <- string(Enum.to_list(?a..?z), min_length: 1, max_length: 12),
          revision <-
            one_of([
              constant(%{kind: :default}),
              map(
                string(Enum.to_list(?a..?z), min_length: 1, max_length: 8),
                &%{kind: :ref, value: &1}
              )
            ])
        ) do
      %{provider: :github, namespace: namespace, repository: repository, revision: revision}
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] claim-shape-ignores-workspace-source-tested
  # A ready claim MUST match the same placement's spec whether or not the
  # current command carries a workspace source, and MUST refuse any change to
  # the persisted shape, so a running source whose start command carries a
  # source still prunes, captures and adopts.
  @tag :hegel
  test "a ready claim matches its spec with or without a workspace source", %{tmp_dir: tmp_dir} do
    check all(source <- source_gen(), test_cases: 25) do
      path = Path.join(tmp_dir, Lilly.UUID.generate())
      File.mkdir_p!(path)
      pool = pool(path)
      placement = Lilly.UUID.generate()
      stopped = spec(pool, placement)
      started = %{stopped | workspace_source: source}
      plant_ready_claim(pool, stopped)

      assert {:ok, %{state: "ready", dataset_guid: @guid} = claim} =
               ZFSDataset.snapshot_claim(pool, placement)

      assert claim.spec == stopped
      refute claim.spec == started
      assert ZFSDataset.claim_matches?(claim, stopped)
      assert ZFSDataset.claim_matches?(claim, started)

      for changed <- [
            %{started | disk_bytes: stopped.disk_bytes + 4096},
            %{started | vcpu: 2},
            %{started | memory_bytes: stopped.memory_bytes * 2},
            %{started | image_id: "sha256:" <> String.duplicate("b", 64)}
          ] do
        refute ZFSDataset.claim_matches?(claim, changed)
      end

      refute ZFSDataset.claim_matches?(%{claim | state: "creating", spec: nil}, started)
    end
  end
end
