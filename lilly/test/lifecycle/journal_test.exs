defmodule Lilly.Lifecycle.JournalTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Lifecycle.{Dataset, Journal}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    host = Lilly.UUID.generate()
    placement = Lilly.UUID.generate()

    payload = %{
      "state" => "creating",
      "binding" => %{"host_id" => host, "spec" => %{"id" => placement}}
    }

    %{root: root, host: host, placement: placement, payload: payload}
  end

  test "unlocked transitions fail without materializing a journal", c do
    assert {:error, _} = Journal.write(Dataset, c.root, "claim.json", c.payload)
    refute File.exists?(Path.join(c.root, "claim.json"))
  end

  test "reopening and replay preserve exact state identity and revision", c do
    locked(c.root, fn ->
      assert :ok = Journal.write(Dataset, c.root, "claim.json", c.payload)
      assert {:ok, first} = Journal.load(Dataset, c.root, "claim.json")
      bytes = File.read!(Path.join(c.root, "claim.json"))
      assert :ok = Journal.write(Dataset, c.root, "claim.json", c.payload)
      assert {:ok, ^first} = Journal.load(Dataset, c.root, "claim.json")
      assert File.read!(Path.join(c.root, "claim.json")) == bytes
      assert :ok = Journal.write(Dataset, c.root, "claim.json", %{c.payload | "state" => "bound"})

      assert {:ok, %{revision: 2, state: :bound, id: id}} =
               Journal.load(Dataset, c.root, "claim.json")

      assert id == first.id
    end)
  end

  # @cc [owner:ghuntley,label:verification;recovery;observability] diagnostics-outage-state-only
  # More than the old 64-event bound MUST commit without a collector
  # acknowledgement. Reopening MUST retain the same authority and no event queue.
  @tag :hegel
  test "collector outage cannot bound state history", c do
    check all(count <- integer(65..96), test_cases: 8) do
      directory = Path.join(c.root, Lilly.UUID.generate())

      locked(directory, fn ->
        for revision <- 1..count do
          assert :ok =
                   Journal.write(
                     Dataset,
                     directory,
                     "claim.json",
                     Map.put(c.payload, "revision_fixture", revision)
                   )
        end

        assert :ok =
                 Journal.write(
                   Dataset,
                   directory,
                   "claim.json",
                   Map.put(c.payload, "revision_fixture", count + 1)
                 )

        assert {:ok, %{revision: revision}} = Journal.load(Dataset, directory, "claim.json")
        assert revision == count + 1

        assert {:ok, _, metadata} =
                 Path.join(directory, "claim.json") |> File.read!() |> Journal.envelope()

        assert metadata["version"] == 2
        refute Map.has_key?(metadata, "events")
      end)
    end
  end

  test "only version-2 envelopes load; other versions fail closed without rewriting", c do
    locked(c.root, fn ->
      assert :ok = Journal.write(Dataset, c.root, "claim.json", c.payload)
      path = Path.join(c.root, "claim.json")
      value = path |> File.read!() |> JSON.decode!()

      for metadata <- [
            value["_lifecycle"] |> Map.put("version", 1) |> Map.put("events", []),
            Map.put(value["_lifecycle"], "version", 1),
            Map.put(value["_lifecycle"], "version", 3)
          ] do
        bytes = JSON.encode!(%{value | "_lifecycle" => metadata})
        assert :ok = PrivateFiles.write(c.root, "claim.json", bytes)
        assert {:error, _} = Journal.load(Dataset, c.root, "claim.json")
        assert {:error, _} = Journal.write(Dataset, c.root, "claim.json", c.payload)
        assert File.read!(path) == bytes
        assert File.ls!(c.root) |> Enum.reject(&(&1 == "owner.lock")) == ["claim.json"]
      end
    end)
  end

  @tag :hegel
  test "arbitrary histories cannot skip materialization or resurrect deleted datasets", c do
    check all(
            targets <-
              list_of(member_of(~w(creating bound ready deleting deleted)), max_length: 15),
            test_cases: 20
          ) do
      directory = Path.join(c.root, Lilly.UUID.generate())

      locked(directory, fn ->
        assert :ok = Journal.write(Dataset, directory, "claim.json", c.payload)

        Enum.reduce(targets, "creating", fn target, state ->
          allowed =
            case state do
              "creating" -> target in ~w(creating bound deleting)
              "bound" -> target in ~w(bound ready deleting)
              "ready" -> target in ~w(ready deleting)
              "deleting" -> target in ~w(deleting deleted)
              "deleted" -> target == "deleted"
            end

          result =
            Journal.write(Dataset, directory, "claim.json", %{c.payload | "state" => target})

          assert result == :ok == allowed
          assert {:ok, record} = Journal.load(Dataset, directory, "claim.json")
          expected = if allowed, do: target, else: state
          assert Atom.to_string(record.state) == expected
          expected
        end)
      end)
    end
  end

  defp locked(directory, callback) do
    {:ok, lock} = Lock.acquire(directory)

    try do
      callback.()
    after
      Lock.release(lock)
    end
  end
end
