defmodule Lilly.Clone.RuntimeCadenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Clone.Runtime

  property "only effects first offered in this exchange trigger an immediate follow-up" do
    check all(
            previous <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 8),
            fresh <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 4),
            reoffered <- sublist(previous)
          ) do
      fresh = Enum.reject(fresh, &(&1 in previous))
      offered = MapSet.new(previous)

      # Re-executing purposely re-offered effects (capture permit renewal) keeps cadence.
      refute Runtime.fresh_execution?(offered, reoffered)
      assert Runtime.fresh_execution?(offered, reoffered ++ fresh) == (fresh != [])
    end
  end

  defp sublist(list),
    do: map(list_of(member_of([true, false]), length: length(list)), &pick(list, &1))

  defp pick(list, flags), do: for({item, true} <- Enum.zip(list, flags), do: item)
end
