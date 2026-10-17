defmodule Lilly.Host.LockOrderTest do
  # The recorded pairs are BEAM-global, so these tests run alone.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Lilly.Host.LockOrder

  @directories %{
    host_owner: "/run/lilly",
    placement: "/var/lib/lilly/vms/a/lock",
    launch_intent: "/var/lib/lilly/vms/a/launch",
    pool: "/pool/.lilly-storage",
    network: "/var/lib/lilly/network/network-lock",
    audit: "/var/lib/lilly/vms/a/audit-lock",
    template: "/pool/templates/1"
  }

  setup do
    LockOrder.reset()
    on_exit(&LockOrder.reset/0)
  end

  test "lock directories map to their classes" do
    for {class, directory} <- @directories, do: assert(LockOrder.class(directory) == class)
  end

  # For any sequence of nested acquisitions, an inversion is reported exactly
  # when the reverse pair was recorded earlier, per an independent model
  # (contract lease-order-inversion-reported).
  property "inversions are reported exactly when the reverse order was seen" do
    classes = Map.keys(@directories)

    check all(
            steps <-
              list_of({list_of(member_of(classes), max_length: 3), member_of(classes)},
                max_length: 25
              )
          ) do
      LockOrder.reset()

      {expected, _seen} =
        Enum.reduce(steps, {[], MapSet.new()}, fn {held, acquired}, {reports, seen} ->
          pairs = for h <- Enum.uniq(held), h != acquired, do: {h, acquired}
          new = Enum.reject(pairs, &MapSet.member?(seen, &1))
          inverted = for {h, a} <- new, MapSet.member?(seen, {a, h}), do: {h, a}
          {reports ++ inverted, MapSet.union(seen, MapSet.new(new))}
        end)

      log =
        ExUnit.CaptureLog.capture_log([metadata: [:event, :held_class, :acquired_class]], fn ->
          for {held, acquired} <- steps do
            LockOrder.acquired(Enum.map(held, &@directories[&1]), @directories[acquired])
          end
        end)

      reported =
        for [_, h, a] <- Regex.scan(~r/held_class=(\w+) acquired_class=(\w+)/, log),
            do: {String.to_existing_atom(h), String.to_existing_atom(a)}

      assert reported == expected
    end
  end
end
