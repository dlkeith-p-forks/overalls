defmodule Marshall.Artifacts.StorageQuotaPropertyTest do
  # @cc [owner:ghuntley,label:verification;capacity;security] artifact-storage-quota-model
  # Generated storage histories over an owner, a writer and a viewer MUST match
  # a pure model: each scope accepts exactly up to the 20 MiB cap (keys and
  # values counted), a refused write changes nothing, personal scopes stay per
  # user, viewers never write shared storage, and the usage row always equals
  # the sum of the scope's entries.
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Artifacts.{Limits, Publisher, Sharing, Storage, StorageEntry, StorageUsage}
  alias Marshall.Compute.Ledger

  @value_max 5_242_880
  @actors [:owner, :writer, :viewer]
  @namespaces [:personal, :shared]

  @type model :: %{optional({:personal, atom()} | :shared) => %{String.t() => non_neg_integer()}}

  @tag :hegel_case_sandbox
  @tag timeout: 900_000
  property "storage writes match the quota and namespace model", test_cases: 12 do
    Marshall.DataCase.isolate_property_case()
    users = Map.new(@actors, &{&1, Marshall.PasskeyFixture.user(false)})

    {:ok, %{artifact: artifact}} =
      Publisher.publish(users.owner, %{
        artifact_id: nil,
        base_version: 0,
        page: {:content, "storage"},
        via: :web
      })

    for role <- [:writer, :viewer] do
      {:ok, _} =
        Sharing.set_access(
          users.owner,
          artifact.id,
          {:email, to_string(users[role].email)},
          role,
          Ash.UUID.generate()
        )
    end

    steps =
      draw(
        "steps",
        list_of(
          tuple([
            member_of(@actors),
            member_of(@namespaces),
            member_of([:put, :fill, :delete]),
            integer(0, 4),
            integer(-2, 2)
          ]),
          min_length: 1,
          max_length: 10
        )
      )

    Enum.reduce(steps, %{}, fn {actor, namespace, op, slot, offset}, model ->
      model = step(op, actor, namespace, "k#{slot}", offset, artifact.id, users, model)
      assert_usage!(artifact.id, users, model)
      model
    end)
  end

  @tag :hegel_case_sandbox
  @tag timeout: 900_000
  property "a scope accepts exactly up to the storage cap", test_cases: 8 do
    Marshall.DataCase.isolate_property_case()
    owner = Marshall.PasskeyFixture.user(false)
    namespace = draw("namespace", member_of(@namespaces))
    offset = draw("offset", integer(-2, 2))

    {:ok, %{artifact: artifact}} =
      Publisher.publish(owner, %{
        artifact_id: nil,
        base_version: 0,
        page: {:content, "cap"},
        via: :web
      })

    filler = String.duplicate("a", @value_max)

    for key <- ["f0", "f1", "f2"],
        do: assert(:ok == Storage.put(owner, artifact.id, namespace, key, filler))

    used = 3 * (2 + @value_max)
    room = Limits.storage_bytes() - used - byte_size("last")

    result =
      Storage.put(owner, artifact.id, namespace, "last", String.duplicate("b", room + offset))

    scope_id = if namespace == :shared, do: artifact.id, else: owner.id

    [usage] =
      Ledger.read!(StorageUsage,
        artifact_id: artifact.id,
        namespace: namespace,
        scope_id: scope_id
      )

    if offset <= 0 do
      assert result == :ok
      assert usage.bytes == Limits.storage_bytes() + offset
      assert usage.entries == 4
    else
      assert result == {:error, :quota_exceeded}
      assert usage.bytes == used
      assert usage.entries == 3
    end
  end

  @spec step(atom(), atom(), atom(), String.t(), integer(), String.t(), map(), model()) :: model()
  defp step(:delete, actor, namespace, key, _offset, id, users, model) do
    result = Storage.delete(users[actor], id, namespace, key)

    if writable?(actor, namespace) do
      assert result == :ok
      Map.update(model, scope(actor, namespace), %{}, &Map.delete(&1, key))
    else
      assert result == {:error, :forbidden}
      model
    end
  end

  defp step(op, actor, namespace, key, offset, id, users, model) do
    scope = scope(actor, namespace)
    entries = Map.get(model, scope, %{})
    others = entries |> Map.delete(key) |> Map.values() |> Enum.sum()

    # :fill aims exactly at the remaining room (bounded by the per-value cap),
    # shifted by a small offset so both sides of the boundary are exercised.
    value_bytes =
      case op do
        :put -> 16 + offset + 2
        :fill -> min(Limits.storage_bytes() - others - byte_size(key), @value_max) + offset
      end
      |> max(0)
      |> min(@value_max)

    result = Storage.put(users[actor], id, namespace, key, String.duplicate("a", value_bytes))
    size = byte_size(key) + value_bytes

    cond do
      not writable?(actor, namespace) ->
        assert result == {:error, :forbidden}
        model

      others + size > Limits.storage_bytes() ->
        assert result == {:error, :quota_exceeded}
        model

      true ->
        assert result == :ok
        Map.put(model, scope, Map.put(entries, key, size))
    end
  end

  @spec assert_usage!(String.t(), map(), model()) :: :ok
  defp assert_usage!(id, users, model) do
    for actor <- @actors, namespace <- @namespaces do
      scope = scope(actor, namespace)
      scope_id = if namespace == :shared, do: id, else: users[actor].id
      expected = Map.get(model, scope, %{})

      stored =
        Ledger.read!(StorageEntry, artifact_id: id, namespace: namespace, scope_id: scope_id)
        |> Map.new(&{&1.key, &1.bytes})

      assert stored == expected

      usage =
        case Ledger.read!(StorageUsage, artifact_id: id, namespace: namespace, scope_id: scope_id) do
          [usage] -> {usage.bytes, usage.entries}
          [] -> {0, 0}
        end

      assert usage == {expected |> Map.values() |> Enum.sum(), map_size(expected)}
    end

    :ok
  end

  @spec writable?(atom(), atom()) :: boolean()
  defp writable?(:viewer, :shared), do: false
  defp writable?(_actor, _namespace), do: true

  @spec scope(atom(), atom()) :: {:personal, atom()} | :shared
  defp scope(_actor, :shared), do: :shared
  defp scope(actor, :personal), do: {:personal, actor}
end
