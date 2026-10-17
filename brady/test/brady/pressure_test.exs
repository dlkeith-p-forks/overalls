defmodule Brady.Cache.PressureTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.Cache.{Pressure, Store}
  @host "11111111-2222-3333-4444-555555555555"
  @boot "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  @mount "42 1 0:99 / /var/cache/brady rw,relatime - zfs tank/brady rw\n"

  defp config,
    do: %{
      host_id: @host,
      cache_dataset: "tank/brady",
      cache_directory: "/var/cache/brady",
      limits: %{quota: 10_000_000}
    }

  defp observation do
    %{
      "version" => 1,
      "host_id" => @host,
      "dataset" => "tank/brady",
      "device" => "0:99",
      "boot_id" => @boot,
      "observed_ms" => 10_000,
      "pool_total_bytes" => 100_000_000,
      "pool_available_bytes" => 90_000_000,
      "parent_total_bytes" => 100_000_000,
      "parent_available_bytes" => 90_000_000,
      "cache_quota_bytes" => 20_000_000
    }
  end

  test "pressure requires fresh boot, exact local ZFS mount and closed native values" do
    assert {:ok, {"42", "0:99", "tank/brady"}, p} =
             Pressure.validate(observation(), config(), @mount, 11_000, @boot)

    assert p.quota == 10_000_000
    assert p.deadline <= System.monotonic_time(:millisecond) + 2000

    for {key, value} <- [
          {"boot_id", "old"},
          {"device", "0:98"},
          {"host_id", "old"},
          {"observed_ms", 11_001},
          {"pool_available_bytes", 100_000_001},
          {"cache_quota_bytes", 0},
          {"unexpected", 1}
        ] do
      assert :error =
               Pressure.validate(
                 Map.put(observation(), key, value),
                 config(),
                 @mount,
                 11_000,
                 @boot
               )
    end

    assert {:stale, {"42", "0:99", "tank/brady"}} =
             Pressure.validate(
               Map.put(observation(), "observed_ms", 7999),
               config(),
               @mount,
               11_000,
               @boot
             )

    for mount <- [
          String.replace(@mount, " zfs ", " ext4 "),
          String.replace(@mount, "rw,", "ro,"),
          String.replace(@mount, "tank/brady", "tank/unowned"),
          @mount <> @mount
        ] do
      assert :error = Pressure.validate(observation(), config(), mount, 11_000, @boot)
    end
  end

  test "expired queued observations and guest-parent pressure cannot enable writes" do
    root = Path.join(System.tmp_dir!(), "brady-pressure-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    store =
      start_supervised!(
        {Store,
         root: root,
         limits: %{quota: 10_000_000, object: 1_000_000, high: 9_000_000, low: 8_000_000}}
      )

    assert {:ok, _, pressure} = Pressure.validate(observation(), config(), @mount, 10_000, @boot)
    :ok = Store.observe_native(store, pressure)
    assert Store.stats(store).writable

    :ok =
      Store.observe_native(store, %{pressure | deadline: System.monotonic_time(:millisecond) - 1})

    refute Store.stats(store).writable
    :ok = Store.observe_native(store, %{pressure | parent_available: 19_000_000})
    refute Store.stats(store).writable
    :ok = Store.observe_native(store, %{pressure | parent_available: 90_000_000})
    assert Store.stats(store).writable
  end

  # @cc [owner:ghuntley,label:verification;capacity] brady-stale-keeps-cache
  # A late observation and the resume hysteresis band MUST keep every complete
  # object (read-only); only headroom below the floor may empty the cache.
  test "late or hysteresis-band evidence pauses writes without emptying the cache" do
    root = Path.join(System.tmp_dir!(), "brady-keep-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    store =
      start_supervised!(
        {Store,
         root: root,
         limits: %{quota: 10_000_000, object: 1_000_000, high: 9_000_000, low: 8_000_000}}
      )

    {:ok, _, pressure} = Pressure.validate(observation(), config(), @mount, 10_000, @boot)
    :ok = Store.observe_native(store, pressure)

    {:ok, ref} =
      Store.begin_write(
        store,
        String.duplicate("a", 64),
        %{"stored_at" => 100, "expires_at" => 200},
        4
      )

    :ok = Store.append(store, ref, "data")
    :ok = Store.commit(store, ref)
    assert Store.stats(store).objects == 1

    # A late (already expired) observation: read-only, cache kept.
    :ok =
      Store.observe_native(store, %{pressure | deadline: System.monotonic_time(:millisecond) - 1})

    refute Store.stats(store).writable
    assert Store.stats(store).objects == 1

    # Paused, then 17 percent free: inside the 15-20 percent hysteresis band.
    :ok = Store.observe_native(store, %{pressure | available: 17_000_000})
    refute Store.stats(store).writable
    assert Store.stats(store).objects == 1

    # Below the 15 percent floor: real pressure empties the cache.
    :ok = Store.observe_native(store, %{pressure | available: 10_000_000})
    assert Store.stats(store).objects == 0
  end

  test "a shrinking native quota prevents existing reservations from continuing" do
    root = Path.join(System.tmp_dir!(), "brady-shrink-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    store =
      start_supervised!(
        {Store,
         root: root,
         limits: %{quota: 10_000_000, object: 1_000_000, high: 9_000_000, low: 8_000_000}}
      )

    {:ok, _, pressure} = Pressure.validate(observation(), config(), @mount, 10_000, @boot)
    Store.observe_native(store, pressure)

    refs =
      for char <- ["a", "b", "c"] do
        {:ok, ref} =
          Store.begin_write(
            store,
            String.duplicate(char, 64),
            %{"stored_at" => 100, "expires_at" => 200},
            1_000_000
          )

        ref
      end

    Store.observe_native(store, %{pressure | quota: 1_048_576})
    refute Store.stats(store).writable
    for ref <- refs, do: assert(:bypass == Store.append(store, ref, "x"))
    assert Store.stats(store).pending == 0
  end

  property "freshness never substitutes for boot or mount custody" do
    check all(age <- integer(0..100_000), bad <- member_of(["boot_id", "device", "host_id"])) do
      sample = Map.put(observation(), "observed_ms", 100_000 - age)
      result = Pressure.validate(sample, config(), @mount, 100_000, @boot)

      if age <= 3000 do
        assert {:ok, {"42", "0:99", "tank/brady"}, _} = result
      else
        assert {:stale, {"42", "0:99", "tank/brady"}} = result
      end

      assert :error =
               Pressure.validate(
                 Map.put(sample, bad, "foreign"),
                 config(),
                 @mount,
                 100_000,
                 @boot
               )
    end
  end
end
