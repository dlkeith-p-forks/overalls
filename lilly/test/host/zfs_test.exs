defmodule Lilly.Host.ZFSTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.ZFS
  @vm "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @name "tank/lilly/vm-#{@vm}"
  @identity %{
    path: "/pool",
    filesystem_id: "zfs:1:2",
    storage: %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "tank/lilly"},
    extents: []
  }

  test "incoherent native reads retry complete validation without reusing rejected credit" do
    counter = :counters.new(1, [])

    assert {:ok, %{free_bytes: 7}} =
             ZFS.resample_observation(fn ->
               :counters.add(counter, 1, 1)

               if :counters.get(counter, 1) < 3,
                 do: {:sample, %{}, :retry},
                 else: {:sample, %{}, {:ok, %{free_bytes: 7}}}
             end)

    assert :counters.get(counter, 1) == 3
  end

  test "persistent incoherence fails after three attempts instead of granting credit" do
    counter = :counters.new(1, [])

    assert {:error, :incoherent_zfs_observation} =
             ZFS.resample_observation(fn ->
               :counters.add(counter, 1, 1)
               {:sample, %{}, :retry}
             end)

    assert :counters.get(counter, 1) == 3
  end

  test "coherent observations, usage-only races and other errors are not retried" do
    for result <- [
          {:ok, %{free_bytes: 0}},
          {:error, :storage_busy},
          {:error, :unsupported_zfs_pool}
        ] do
      counter = :counters.new(1, [])

      assert ZFS.resample_observation(fn ->
               :counters.add(counter, 1, 1)

               if match?({:error, :unsupported_zfs_pool}, result),
                 do: result,
                 else: {:sample, %{}, result}
             end) == result

      assert :counters.get(counter, 1) == 1
    end
  end

  test "moving usage counters resample three times and then take the latest coherent tree" do
    counter = :counters.new(1, [])

    assert {:ok, %{free_bytes: 3}} =
             ZFS.resample_observation(fn ->
               :counters.add(counter, 1, 1)
               n = :counters.get(counter, 1)
               {:sample, %{"pool" => %{"guid" => "1"}}, {:retry_usage, %{free_bytes: n}}}
             end)

    assert :counters.get(counter, 1) == 3

    settled = :counters.new(1, [])

    assert {:ok, %{free_bytes: 7}} =
             ZFS.resample_observation(fn ->
               :counters.add(settled, 1, 1)

               if :counters.get(settled, 1) == 1,
                 do: {:sample, %{"pool" => %{"guid" => "1"}}, {:retry_usage, %{free_bytes: 1}}},
                 else: {:sample, %{"pool" => %{"guid" => "1"}}, {:ok, %{free_bytes: 7}}}
             end)

    assert :counters.get(settled, 1) == 2
  end

  test "a later coherent sample cannot hide changed non-usage properties" do
    for property <- ["guid", "quota", "mountpoint", "readonly"] do
      counter = :counters.new(1, [])

      assert {:error, :incoherent_zfs_observation} =
               ZFS.resample_observation(fn ->
                 :counters.add(counter, 1, 1)

                 if :counters.get(counter, 1) == 1,
                   do: {:sample, %{"pool" => %{property => "original"}}, :retry},
                   else:
                     {:sample, %{"pool" => %{property => "changed"}}, {:ok, %{free_bytes: 99}}}
               end)

      assert :counters.get(counter, 1) == 2
    end
  end

  @usage ~w(used available logicalused compressratio usedbychildren usedbydataset usedbysnapshots)

  property "identity observations tolerate usage-only drift that exact observations refuse" do
    base =
      draw(
        "base",
        map(
          list_of(tuple({member_of(@usage), integer(0..1_000_000)}), min_length: 1),
          &Map.new/1
        )
      )

    drift =
      draw(
        "drift",
        map(
          list_of(tuple({member_of(@usage), integer(0..1_000_000)}), min_length: 1),
          &Map.new/1
        )
      )

    guid = draw("guid", string(Enum.to_list(48..57), min_length: 1, max_length: 8))
    before = %{@name => Map.merge(base, %{"guid" => guid, "mountpoint" => "/pool/vm"})}
    after_read = %{@name => Map.merge(before[@name], drift)}
    accounting = {:ok, %{children: %{@name => %{dataset_guid: guid}}}}

    # Usage-only changes never alter the non-usage fingerprint that fences identity.
    assert ZFS.stable_properties(before) == ZFS.stable_properties(after_read)

    assert ZFS.decide_sample(before, after_read, accounting, accounting, :identity) ==
             accounting

    # An exact observation asks for a bounded resample carrying the later
    # coherent tree instead of withholding the pool for ordinary writes.
    assert ZFS.decide_sample(before, after_read, accounting, accounting, :exact) ==
             if(before == after_read, do: accounting, else: {:retry_usage, elem(accounting, 1)})
  end

  property "identity observations still require coherent accounting and stable identity" do
    property = draw("property", member_of(~w(guid origin mountpoint quota readonly)))
    usage = draw("usage", member_of([:exact, :identity]))
    rejected = draw("rejected", member_of([:before, :after, :both]))
    tree = %{@name => %{"guid" => "1", property => "original", "used" => 1}}
    changed = %{@name => %{"guid" => "1", property => "changed", "used" => 1}}
    refute ZFS.stable_properties(tree) == ZFS.stable_properties(changed)

    ok = {:ok, %{children: %{}}}

    {first, second} =
      case rejected do
        :before -> {:error, ok}
        :after -> {ok, :error}
        :both -> {:error, :error}
      end

    assert ZFS.decide_sample(tree, tree, first, second, usage) == :retry
  end

  property "logical usage and compression do not become exclusive physical usage" do
    child = draw("child", integer(0..1_000_000))
    metadata = draw("metadata", integer(0..1_000_000))
    free = draw("free", integer(0..1_000_000))
    logical = draw("logical", integer(0..1_000_000_000))
    ratio = draw("ratio", integer(1..1000))

    parent =
      row("tank/lilly", "/pool", "2", %{
        "used" => child + metadata,
        "available" => free,
        "usedbychildren" => child,
        "usedbydataset" => metadata,
        "logicalused" => logical,
        "compressratio" => ratio * 1.0
      })

    vm = row(@name, "/pool/vms/#{@vm}", "3", %{"used" => child, "usedbydataset" => child})
    assert {:ok, result} = ZFS.accounting(%{"tank/lilly" => parent, @name => vm}, @identity)
    assert result.total_bytes == child + metadata + free
    assert result.free_bytes == free
    assert %{dataset_guid: "3", physical_bytes: ^child} = result.children[@name]
    assert result.storage.logical_used_bytes == logical
    refute Map.has_key?(result, :allocations)
  end

  property "arbitrary native property bytes never crash" do
    output = draw("output", binary(max_length: 4096))

    case ZFS.parse_datasets(output) do
      :error -> :ok
      {:ok, rows} -> assert map_size(rows) in 1..16_385
    end
  end

  property "template physical allocation remains measured storage, never VM credit" do
    used = draw("used", integer(0..1_000_000))
    free = draw("free", integer(0..1_000_000))
    logical = draw("logical", integer(0..1_000_000_000))
    seal = draw("seal", member_of(["on", "off"]))
    id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    name = "tank/lilly/template-" <> id

    parent =
      row("tank/lilly", "/pool", "2", %{
        "used" => used + 7,
        "usedbychildren" => used,
        "usedbydataset" => 7,
        "available" => free
      })

    template =
      row(name, "/pool/templates/" <> id, "3", %{
        "used" => used,
        "usedbydataset" => used,
        "logicalused" => logical,
        "readonly" => seal
      })

    tree = %{"tank/lilly" => parent, name => template}
    assert {:ok, observation} = ZFS.accounting(tree, @identity)
    assert observation.total_bytes == used + 7 + free
    assert observation.free_bytes == free
    assert observation.children[name].physical_bytes == used
    refute Map.has_key?(observation, :allocations)
    assert :error = ZFS.accounting(put_in(tree, [name, "guid"], "2"), @identity)

    assert :error =
             ZFS.accounting(put_in(tree, [name, "origin"], "tank/foreign@origin"), @identity)

    assert :error = ZFS.accounting(put_in(tree, [name, "mountpoint"], "/foreign"), @identity)
  end

  # @cc [owner:ghuntley,label:verification;capacity] retired-standby-is-unknown-storage
  # After ADR-0177 a `standby-*` child MUST withhold the pool wherever it is
  # mounted; accounting never measures it as owned storage.
  property "retired standby datasets withhold the pool wherever they are mounted" do
    used = draw("used", integer(0..1_000_000))
    seal = draw("seal", member_of(["on", "off"]))
    mount = draw("mount", member_of([:standby, :claimed, :foreign, :template, :nested]))
    id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    placement = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    name = "tank/lilly/standby-" <> id

    mountpoint =
      case mount do
        :standby -> "/pool/standbys/" <> id
        :claimed -> "/pool/vms/" <> placement
        :foreign -> "/foreign/standbys/" <> id
        :template -> "/pool/templates/" <> id
        :nested -> "/pool/vms/" <> placement <> "/x"
      end

    parent =
      row("tank/lilly", "/pool", "2", %{
        "used" => used + 7,
        "usedbychildren" => used,
        "usedbydataset" => 7,
        "available" => 5
      })

    standby =
      row(name, mountpoint, "3", %{"used" => used, "usedbydataset" => used, "readonly" => seal})

    assert :error = ZFS.accounting(%{"tank/lilly" => parent, name => standby}, @identity)
  end

  # @cc [owner:ghuntley,label:verification;capacity] incoming-sibling-refuses-pool-credit
  # An otherwise valid source and bound snapshots MUST NOT make whole-pool
  # accounting accept a sibling with receive-staging policy. This pure boundary
  # check MUST NOT establish the cause of a native retained-disk readiness failure.
  test "same-pool incoming staging refuses capacity despite a valid source snapshot tree" do
    {source, bindings} = snapshot_tree(100, 50, 10, 20)
    sibling = "tank/lilly/vm-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    mounted = row(sibling, "/pool/vms/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "6")

    assert {:ok, observation} = ZFS.accounting(source, @identity, bindings)
    assert observation.children[@name].dataset_guid == "3"
    assert observation.snapshots == bindings

    assert {:ok, _} = ZFS.accounting(Map.put(source, sibling, mounted), @identity, bindings)

    for policy <- [
          %{"mounted" => "no"},
          %{"readonly" => "on"},
          %{"canmount" => "noauto"},
          %{"mounted" => "no", "readonly" => "on", "canmount" => "noauto"}
        ] do
      staging = Map.merge(mounted, policy)
      assert :error = ZFS.accounting(Map.put(source, sibling, staging), @identity, bindings)
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity] same-pool-copy-snapshot-guids
  # zfs receive preserves snapshot GUIDs, so a staged same-pool clone copy MUST be
  # accepted with its source's snapshot GUID; repeated dataset GUIDs and snapshot
  # GUIDs equal to a dataset GUID MUST still be rejected.
  test "a same-pool clone copy may repeat its source's snapshot GUID" do
    {source, bindings} = snapshot_tree(100, 50, 10, 20)
    sibling = "tank/lilly/vm-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    mountpoint = "/pool/vms/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    received = sibling <> "@lilly-b"
    staged = MapSet.new([sibling])

    staging =
      row(sibling, mountpoint, "6", %{
        "mounted" => "no",
        "readonly" => "on",
        "canmount" => "noauto"
      })

    snapshot = fn guid ->
      ZFS.properties()
      |> Map.new(&{&1, "-"})
      |> Map.merge(%{
        "name" => received,
        "type" => "snapshot",
        "guid" => guid,
        "used" => 0,
        "compressratio" => 1.0
      })
    end

    copy = fn guid ->
      {Map.merge(source, %{sibling => staging, received => snapshot.(guid)}),
       Map.put(bindings, received, %{dataset_guid: "6", snapshot_guid: guid})}
    end

    # "5" is the source's own lilly-b snapshot GUID, preserved by zfs receive.
    {tree, expected} = copy.("5")
    assert {:ok, _} = ZFS.classify_accounting(tree, @identity, expected, staged)

    # A snapshot GUID equal to a dataset GUID still identifies nothing uniquely.
    {tree, expected} = copy.("3")

    assert {:error, :duplicate_guid} =
             ZFS.classify_accounting(tree, @identity, expected, staged)

    # Two datasets with one GUID remain refused.
    assert {:error, :duplicate_guid} =
             ZFS.classify_accounting(
               Map.put(source, sibling, %{staging | "guid" => "3"}),
               @identity,
               bindings,
               staged
             )
  end

  test "restart readiness accepts only declared, finished staging under receive policy" do
    {source, bindings} = snapshot_tree(100, 50, 10, 20)
    sibling = "tank/lilly/vm-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    mountpoint = "/pool/vms/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    staging =
      row(sibling, mountpoint, "6", %{
        "mounted" => "no",
        "readonly" => "on",
        "canmount" => "noauto"
      })

    tree = Map.put(source, sibling, staging)
    staged = MapSet.new([sibling])

    # Capacity accounting never adopts staging; readiness may name it staged.
    assert :error = ZFS.accounting(tree, @identity, bindings)
    assert {:error, :child} = ZFS.classify_accounting(tree, @identity, bindings, MapSet.new())

    assert {:error, :staged_child} =
             ZFS.classify_accounting(
               Map.put(source, sibling, row(sibling, mountpoint, "6")),
               @identity,
               bindings,
               staged
             )

    assert {:ok, _} = ZFS.accounting(tree, @identity, bindings, staged)

    # A staged name must still look like an untouched receive: no live policy.
    for live <- [%{"mounted" => "yes"}, %{"readonly" => "off"}, %{"canmount" => "on"}] do
      assert :error =
               ZFS.accounting(
                 Map.put(source, sibling, Map.merge(staging, live)),
                 @identity,
                 bindings,
                 staged
               )
    end

    # Declaring an absent or different name grants nothing to real staging.
    assert :error = ZFS.accounting(tree, @identity, bindings, MapSet.new(["tank/lilly/vm-other"]))
  end

  test "parser preserves unsigned GUID strings and rejects duplicate, noncanonical and excessive rows" do
    parent = row("tank/lilly", "/pool", "18446744073709551615")
    wire = encode(parent)
    assert {:ok, %{"tank/lilly" => ^parent}} = ZFS.parse_datasets(wire)
    assert :error = ZFS.parse_datasets(wire <> wire)
    assert :error = ZFS.parse_datasets(String.trim_trailing(wire, "\n"))
    assert :error = ZFS.parse_datasets(encode(%{parent | "guid" => "18446744073709551616"}))
    assert :error = ZFS.parse_datasets(encode(%{parent | "used" => "01"}))
    assert :error = ZFS.parse_datasets(encode(%{parent | "quota" => "9223372036854775808"}))
    assert :error = ZFS.parse_datasets(String.duplicate("x", 4_194_305))

    many = Enum.map_join(1..16_385, fn n -> encode(%{parent | "name" => "tank/item#{n}"}) end)
    assert byte_size(many) > 65_536
    assert {:ok, parsed} = ZFS.parse_datasets(many)
    assert map_size(parsed) == 16_385
    assert :error = ZFS.parse_datasets(many <> encode(parent))
  end

  test "native snapshot rows preserve not-applicable fields without granting allocation credit" do
    [header, wire] =
      Path.expand("../fixtures/zfs_snapshot_properties.tsv", __DIR__)
      |> File.read!()
      |> String.split("\n", parts: 2)

    assert String.split(header, ",") == ZFS.properties()
    assert {:ok, rows} = ZFS.parse_datasets(wire)
    snapshot = rows["tank/lilly/child@baseline"]
    assert snapshot["guid"] == "17849690617919238879"
    assert snapshot["used"] == 1_062_912
    assert snapshot["compressratio"] == 1.0
    assert rows["tank/lilly/child@final"]["used"] == 0

    absent = ZFS.properties() -- ~w(name type guid used compressratio)

    for property <- absent do
      assert snapshot[property] == "-"
      assert :error = ZFS.parse_datasets(encode(Map.put(snapshot, property, 0)))
    end

    for used <- ["-", "01", "-1", "9223372036854775808"] do
      assert :error = ZFS.parse_datasets(encode(%{snapshot | "used" => used}))
    end

    for name <- ["tank/lilly/child", "tank/lilly/child@", "@baseline", "tank/x@a@b"] do
      assert :error = ZFS.parse_datasets(encode(%{snapshot | "name" => name}))
    end

    assert :error = ZFS.parse_datasets(encode(%{snapshot | "type" => "filesystem"}))
    parent = row("tank/lilly", "/pool", "2")
    assert {:ok, _} = ZFS.accounting(%{"tank/lilly" => parent}, @identity)

    assert :error =
             ZFS.accounting(%{"tank/lilly" => parent, snapshot["name"] => snapshot}, @identity)
  end

  property "retained blocks shared by transfer snapshots are counted once from the child" do
    current = draw("current", integer(0..1_000_000))
    retained = draw("retained", integer(0..1_000_000))
    exclusive_a = draw("exclusive_a", integer(0..retained))
    exclusive_b = draw("exclusive_b", integer(0..(retained - exclusive_a)))
    {tree, bindings} = snapshot_tree(current, retained, exclusive_a, exclusive_b)
    assert {:ok, observation} = ZFS.accounting(tree, @identity, bindings)
    assert observation.children[@name].physical_bytes == current + retained
    assert observation.snapshots == bindings
    refute Map.has_key?(observation, :allocations)
    assert :error = ZFS.accounting(tree, @identity)
  end

  test "snapshot expectations bind exact child and snapshot GUIDs and permit no extra entries" do
    {tree, bindings} = snapshot_tree(100, 50, 10, 20)
    a = @name <> "@lilly-backup"
    b = @name <> "@lilly-b"
    assert {:ok, _} = ZFS.accounting(tree, @identity, bindings)

    for changed <- [
          Map.delete(bindings, a),
          put_in(bindings, [a, :dataset_guid], "99"),
          put_in(bindings, [a, :snapshot_guid], "99"),
          put_in(bindings, [a, :snapshot_guid], "04"),
          put_in(bindings, [a, :dataset_guid], "03"),
          put_in(bindings, [a, :extra], "untrusted"),
          Map.put(bindings, @name <> "@foreign", bindings[a]),
          Map.put(bindings, 42, bindings[a])
        ] do
      assert :error = ZFS.accounting(tree, @identity, changed)
    end

    for changed <- [
          Map.delete(tree, a),
          Map.delete(tree, @name),
          put_in(tree, [a, "guid"], "99"),
          put_in(tree, [@name, "guid"], "99"),
          put_in(tree, [a, "name"], b),
          put_in(tree, [a, "used"], 51),
          put_in(tree, [a, "available"], 0),
          put_in(tree, [a, "compressratio"], 0.0),
          put_in(tree, [a, "type"], "bookmark"),
          put_in(tree, [@name, "origin"], "tank/clone@source"),
          put_in(tree, [@name, "used"], 149),
          put_in(tree, [@name, "usedbysnapshots"], 49),
          put_in(tree, ["tank/lilly", "usedbychildren"], 149),
          Map.put(tree, @name <> "@foreign", %{tree[a] | "name" => @name <> "@foreign"})
        ] do
      assert :error = ZFS.accounting(changed, @identity, bindings)
    end

    # A source path may not be replaced with another valid placement's path.
    other = "tank/lilly/vm-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb@lilly-backup"
    assert :error = ZFS.accounting(tree, @identity, Map.put(bindings, other, bindings[a]))
    assert :error = ZFS.accounting(tree, @identity, nil)
  end

  # ADR-0155 removed the running-source baseline snapshot: "lilly-a" is no
  # longer an expectable transfer snapshot name, even with exact GUIDs.
  test "the removed lilly-a baseline snapshot is never an admissible expectation" do
    {tree, bindings} = snapshot_tree(100, 50, 10, 20)
    backup = @name <> "@lilly-backup"
    removed = @name <> "@lilly-a"
    tree = Map.put(Map.delete(tree, backup), removed, %{tree[backup] | "name" => removed})
    bindings = Map.put(Map.delete(bindings, backup), removed, bindings[backup])
    assert :error = ZFS.accounting(tree, @identity, bindings)
  end

  test "one final snapshot works while parent snapshots and duplicate GUIDs remain rejected" do
    {tree, bindings} = snapshot_tree(100, 50, 10, 20)
    a = @name <> "@lilly-backup"
    b = @name <> "@lilly-b"
    assert {:ok, _} = ZFS.accounting(Map.delete(tree, a), @identity, Map.delete(bindings, a))

    duplicate = put_in(bindings, [b, :snapshot_guid], bindings[a].snapshot_guid)

    assert :error =
             ZFS.accounting(put_in(tree, [b, "guid"], tree[a]["guid"]), @identity, duplicate)

    parent_snapshot = "tank/lilly@lilly-backup"

    parent_tree =
      Map.put(tree, parent_snapshot, %{tree[a] | "name" => parent_snapshot, "guid" => "6"})

    parent_binding = Map.put(bindings, parent_snapshot, %{dataset_guid: "2", snapshot_guid: "6"})
    assert :error = ZFS.accounting(parent_tree, @identity, parent_binding)
  end

  defp snapshot_tree(current, retained, exclusive_a, exclusive_b) do
    a = @name <> "@lilly-backup"
    b = @name <> "@lilly-b"

    parent =
      row("tank/lilly", "/pool", "2", %{
        "used" => current + retained + 10,
        "usedbychildren" => current + retained,
        "usedbydataset" => 10
      })

    child =
      row(@name, "/pool/vms/#{@vm}", "3", %{
        "used" => current + retained,
        "usedbydataset" => current,
        "usedbysnapshots" => retained
      })

    snapshots =
      Enum.map([{a, "4", exclusive_a}, {b, "5", exclusive_b}], fn {name, guid, used} ->
        empty = Map.new(ZFS.properties(), &{&1, "-"})

        {name,
         Map.merge(empty, %{
           "name" => name,
           "type" => "snapshot",
           "guid" => guid,
           "used" => used,
           "compressratio" => 1.0
         })}
      end)

    tree = Map.new([{"tank/lilly", parent}, {@name, child} | snapshots])

    bindings = %{
      a => %{dataset_guid: "3", snapshot_guid: "4"},
      b => %{dataset_guid: "3", snapshot_guid: "5"}
    }

    {tree, bindings}
  end

  test "reservations, unsafe properties, clone origins and accounting drift fail closed" do
    parent = row("tank/lilly", "/pool", "2")
    assert {:ok, _} = ZFS.accounting(%{"tank/lilly" => parent}, @identity)

    for {key, value} <- [
          {"compression", "off"},
          {"dedup", "on"},
          {"sync", "disabled"},
          {"reservation", 1},
          {"refreservation", 1},
          {"refquota", 1},
          {"origin", "tank/source@snap"},
          {"type", "snapshot"},
          {"type", "bookmark"},
          {"usedbysnapshots", 1},
          {"usedbyrefreservation", 1},
          {"usedbychildren", 1},
          {"used", 1},
          {"mounted", "no"},
          {"readonly", "on"},
          {"canmount", "off"},
          {"guid", "3"},
          {"mountpoint", "/alias"}
        ] do
      assert :error = ZFS.accounting(%{"tank/lilly" => Map.put(parent, key, value)}, @identity)
    end

    assert :error =
             ZFS.accounting(
               %{"tank/lilly" => %{parent | "quota" => 1, "available" => 2}},
               @identity
             )

    unknown = row("tank/lilly/unknown", "/pool/unknown", "3")

    assert :error =
             ZFS.accounting(%{"tank/lilly" => parent, unknown["name"] => unknown}, @identity)

    nested = row(@name <> "/nested", "/pool/vms/#{@vm}/nested", "3")
    assert :error = ZFS.accounting(%{"tank/lilly" => parent, nested["name"] => nested}, @identity)
  end

  test "status binds the actual versioned JSON layout and rejects unsupported topology" do
    good = status()
    assert {:ok, "1", ["/dev/vdb1", "/dev/vdc1"]} = ZFS.parse_status(JSON.encode!(good), "tank")

    for {path, value} <- [
          {["output_version", "vers_major"], 1},
          {["pools", "tank", "state"], "DEGRADED"},
          {["pools", "tank", "error_count"], "1"},
          {["pools", "tank", "vdevs", "tank"], []},
          {["pools", "tank", "spares"], %{"unknown" => %{}}},
          {["pools", "tank", "vdevs", "tank", "guid"], "2"},
          {["pools", "tank", "vdevs", "tank", "vdevs", "mirror", "vdev_type"], "raidz"},
          {["pools", "tank", "vdevs", "tank", "vdevs", "mirror", "class"], "special"},
          {["pools", "tank", "vdevs", "tank", "vdevs", "mirror", "vdevs", "a", "path"],
           "/tmp/file"},
          {["pools", "tank", "vdevs", "tank", "vdevs", "mirror", "vdevs", "a", "guid"], "4"}
        ] do
      assert :error = ZFS.parse_status(JSON.encode!(put_in(good, path, value)), "tank")
    end

    leaf = ["pools", "tank", "vdevs", "tank", "vdevs", "mirror", "vdevs", "a"]

    for required <- ~w(vdev_type guid path class state) do
      incomplete = update_in(good, leaf, &Map.delete(&1, required))
      assert :error = ZFS.parse_status(JSON.encode!(incomplete), "tank")
    end
  end

  defp row(name, mount, guid, changes \\ %{}) do
    %{
      "name" => name,
      "type" => "filesystem",
      "guid" => guid,
      "mountpoint" => mount,
      "mounted" => "yes",
      "compression" => "lz4",
      "reservation" => 0,
      "refreservation" => 0,
      "dedup" => "off",
      "sync" => "standard",
      "origin" => "-",
      "used" => 0,
      "available" => 0,
      "logicalused" => 0,
      "quota" => 0,
      "compressratio" => 1.0,
      "usedbychildren" => 0,
      "usedbydataset" => 0,
      "usedbyrefreservation" => 0,
      "usedbysnapshots" => 0,
      "refquota" => 0,
      "readonly" => "off",
      "canmount" => "on"
    }
    |> Map.merge(changes)
  end

  defp encode(row), do: Enum.map_join(ZFS.properties(), "\t", &to_string(row[&1])) <> "\n"

  defp status do
    common = %{
      "class" => "normal",
      "state" => "ONLINE",
      "read_errors" => "0",
      "write_errors" => "0",
      "checksum_errors" => "0"
    }

    a = Map.merge(common, %{"vdev_type" => "disk", "guid" => "3", "path" => "/dev/vdb1"})
    b = %{a | "guid" => "4", "path" => "/dev/vdc1"}

    mirror =
      Map.merge(common, %{
        "vdev_type" => "mirror",
        "guid" => "2",
        "vdevs" => %{"a" => a, "b" => b}
      })

    root =
      Map.merge(common, %{"vdev_type" => "root", "guid" => "1", "vdevs" => %{"mirror" => mirror}})

    %{
      "output_version" => %{"command" => "zpool status", "vers_major" => 0, "vers_minor" => 1},
      "pools" => %{
        "tank" => %{
          "name" => "tank",
          "state" => "ONLINE",
          "pool_guid" => "1",
          "error_count" => "0",
          "vdevs" => %{"tank" => root}
        }
      }
    }
  end
end
