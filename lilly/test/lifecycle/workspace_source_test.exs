defmodule Lilly.Lifecycle.WorkspaceSourceTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.{Journal, WorkspaceSource}
  @moduletag :tmp_dir

  @edges %{
    pending: [:pending, :delivering],
    delivering: [:delivering, :delivered, :failed, :pending],
    delivered: [:delivered, :pending],
    failed: [:failed, :delivering, :pending]
  }
  @states Map.keys(@edges)

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)

    boot = %{
      placement_id: Lilly.UUID.generate(),
      execution_epoch: 3,
      generation: 2,
      boot_challenge: String.duplicate("c", 64)
    }

    %{root: root, host: Lilly.UUID.generate(), boot: boot}
  end

  property "journal transitions match the delivery edge table", c do
    check all(history <- list_of(member_of(@states), max_length: 30), max_runs: 25) do
      directory = Path.join(c.root, Lilly.UUID.generate())
      {:ok, lock} = Lock.acquire(directory)

      try do
        final =
          history
          |> Enum.with_index(1)
          |> Enum.reduce({nil, 0}, fn {target, attempts}, {state, accepted} ->
            payload =
              Lilly.VM.WorkspaceSource.payload(
                c.host,
                c.boot,
                target,
                attempts,
                String.duplicate("d", 64)
              )

            allowed =
              if state, do: target in Map.fetch!(@edges, state), else: target == :pending

            result = Journal.write(WorkspaceSource, directory, "workspace-source.json", payload)
            assert result == :ok == allowed

            {:ok, loaded} = Journal.load(WorkspaceSource, directory, "workspace-source.json")

            if allowed do
              assert loaded.state == target
              {target, accepted + 1}
            else
              assert (loaded && loaded.state) == state
              {state, accepted}
            end
          end)

        {state, accepted} = final

        case Journal.load(WorkspaceSource, directory, "workspace-source.json") do
          {:ok, nil} ->
            assert state == nil

          {:ok, record} ->
            assert record.state == state
            assert record.revision == accepted

            assert {:ok, _, metadata} =
                     Path.join(directory, "workspace-source.json")
                     |> File.read!()
                     |> Journal.envelope()

            assert metadata["version"] == 2
            refute Map.has_key?(metadata, "events")
        end
      after
        Lock.release(lock)
      end
    end
  end

  test "delivered cannot be reached without delivering and settles only its own boot", c do
    directory = Path.join(c.root, "settle")
    {:ok, lock} = Lock.acquire(directory)
    digest = String.duplicate("d", 64)
    payload = &Lilly.VM.WorkspaceSource.payload(c.host, c.boot, &1, &2, digest)

    try do
      assert :ok =
               Journal.write(
                 WorkspaceSource,
                 directory,
                 "workspace-source.json",
                 payload.(:pending, 0)
               )

      assert {:error, _} =
               Journal.write(
                 WorkspaceSource,
                 directory,
                 "workspace-source.json",
                 payload.(:delivered, 0)
               )

      assert :ok =
               Journal.write(
                 WorkspaceSource,
                 directory,
                 "workspace-source.json",
                 payload.(:delivering, 1)
               )

      assert :ok =
               Journal.write(
                 WorkspaceSource,
                 directory,
                 "workspace-source.json",
                 payload.(:delivered, 1)
               )

      delivered = payload.(:delivered, 1)
      assert Lilly.VM.WorkspaceSource.settled?(delivered, c.boot, digest)
      refute Lilly.VM.WorkspaceSource.settled?(delivered, %{c.boot | execution_epoch: 4}, digest)

      refute Lilly.VM.WorkspaceSource.settled?(
               delivered,
               %{c.boot | boot_challenge: String.duplicate("e", 64)},
               digest
             )

      refute Lilly.VM.WorkspaceSource.settled?(delivered, c.boot, String.duplicate("f", 64))
      refute Lilly.VM.WorkspaceSource.settled?(payload.(:delivering, 1), c.boot, digest)
    after
      Lock.release(lock)
    end
  end
end
