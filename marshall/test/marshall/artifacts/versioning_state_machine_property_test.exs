defmodule Marshall.Artifacts.VersioningStateMachinePropertyTest do
  # @cc [owner:ghuntley,label:verification;durability;security] artifact-versioning-model
  # Generated publish, stale publish, edit, storage and delete histories over an
  # owner and a viewer MUST match a pure model: versions stay dense and
  # immutable, stale or missing edits never create a version, viewers never
  # publish or write shared storage, personal storage stays per user, and once
  # deleted every operation is refused.
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Artifacts.{Artifact, Library, Publisher, Sharing, Storage, Version}
  alias Marshall.Compute.Ledger

  @operations [
    :publish,
    :publish_stale,
    :edit,
    :edit_missing,
    :viewer_publish,
    :owner_shared,
    :viewer_shared,
    :viewer_personal,
    :owner_personal,
    :viewer_delete,
    :owner_delete
  ]

  @tag :hegel_case_sandbox
  @tag timeout: 600_000
  property "generated artifact histories match the versioning model", test_cases: 40 do
    Marshall.DataCase.isolate_property_case()
    owner = Marshall.PasskeyFixture.user(false)
    viewer = Marshall.PasskeyFixture.user(false)
    steps = draw("steps", list_of(member_of(@operations), min_length: 1, max_length: 14))

    {:ok, %{artifact: artifact}} =
      Publisher.publish(owner, %{
        artifact_id: nil,
        base_version: 0,
        page: {:content, "v1 seed"},
        via: :web
      })

    {:ok, _} =
      Sharing.set_access(
        owner,
        artifact.id,
        {:email, to_string(viewer.email)},
        :viewer,
        Ash.UUID.generate()
      )

    model = %{version: 1, page: "v1 seed", active: true, shared: %{}, personal: %{}}

    Enum.reduce(Enum.with_index(steps), model, fn {step, index}, model ->
      model = apply_step(step, index, artifact.id, owner, viewer, model)
      assert_matches!(artifact.id, owner, viewer, model)
      model
    end)
  end

  @spec apply_step(atom(), non_neg_integer(), String.t(), struct(), struct(), map()) :: map()
  defp apply_step(:publish, index, id, owner, _viewer, model) do
    page = "page #{index}"
    result = publish(owner, id, model.version, {:content, page})

    if model.active do
      assert {:ok, %{version: %Version{number: number}}} = result
      assert number == model.version + 1
      %{model | version: number, page: page}
    else
      assert {:error, _} = result
      model
    end
  end

  defp apply_step(:publish_stale, _index, id, owner, _viewer, model) do
    result = publish(owner, id, model.version - 1, {:content, "stale"})

    if model.active do
      current = model.version
      assert {:error, :stale_base_version, %{current_version: ^current}} = result
    else
      assert {:error, _} = drop_detail(result)
    end

    model
  end

  defp apply_step(:edit, index, id, owner, _viewer, model) do
    replacement = "edit #{index} "

    result =
      publish(owner, id, model.version, {:edits, [%{old_str: model.page, new_str: replacement}]})

    if model.active do
      assert {:ok, %{version: %Version{number: number}}} = result
      %{model | version: number, page: replacement}
    else
      assert {:error, _} = result
      model
    end
  end

  defp apply_step(:edit_missing, _index, id, owner, _viewer, model) do
    result =
      publish(owner, id, model.version, {:edits, [%{old_str: "\u0000absent", new_str: "x"}]})

    assert {:error, _reason, _} = normalize(result)
    model
  end

  defp apply_step(:viewer_publish, _index, id, _owner, viewer, model) do
    assert {:error, _} = publish(viewer, id, model.version, {:content, "viewer"}) |> drop_detail()
    model
  end

  defp apply_step(:owner_shared, index, id, owner, _viewer, model),
    do: put(owner, id, :shared, "k#{rem(index, 3)}", "o#{index}", model, :shared, true)

  defp apply_step(:viewer_shared, index, id, _owner, viewer, model),
    do: put(viewer, id, :shared, "k#{rem(index, 3)}", "v#{index}", model, :shared, false)

  defp apply_step(:viewer_personal, index, id, _owner, viewer, model),
    do:
      put(
        viewer,
        id,
        :personal,
        "k#{rem(index, 3)}",
        "p#{index}",
        model,
        {:personal, :viewer},
        true
      )

  defp apply_step(:owner_personal, index, id, owner, _viewer, model),
    do:
      put(
        owner,
        id,
        :personal,
        "k#{rem(index, 3)}",
        "q#{index}",
        model,
        {:personal, :owner},
        true
      )

  defp apply_step(:viewer_delete, _index, id, _owner, viewer, model) do
    assert {:error, _} = Library.delete(viewer, id, :web)
    model
  end

  defp apply_step(:owner_delete, _index, id, owner, _viewer, model) do
    # A repeated owner delete is an idempotent no-op on the deleting artifact.
    assert {:ok, %Artifact{state: :deleting}} = Library.delete(owner, id, :web)
    %{model | active: false}
  end

  @spec put(struct(), String.t(), atom(), String.t(), String.t(), map(), term(), boolean()) ::
          map()
  defp put(actor, id, namespace, key, value, model, slot, allowed?) do
    result = Storage.put(actor, id, namespace, key, value)

    if model.active and allowed? do
      assert result == :ok

      case slot do
        :shared -> %{model | shared: Map.put(model.shared, key, value)}
        {:personal, who} -> %{model | personal: Map.put(model.personal, {who, key}, value)}
      end
    else
      assert {:error, _} = result
      model
    end
  end

  @spec publish(struct(), String.t(), integer(), term()) :: term()
  defp publish(actor, id, base, page),
    do:
      Publisher.publish(actor, %{
        artifact_id: id,
        base_version: max(base, 0),
        page: page,
        via: :agent
      })

  defp normalize({:error, reason}), do: {:error, reason, %{}}
  defp normalize(other), do: other
  defp drop_detail({:error, reason, _}), do: {:error, reason}
  defp drop_detail(other), do: other

  @spec assert_matches!(String.t(), struct(), struct(), map()) :: :ok
  defp assert_matches!(id, owner, viewer, model) do
    [artifact] = Ledger.read!(Artifact, id: id)
    numbers = Ledger.read!(Version, artifact_id: id) |> Enum.map(& &1.number) |> Enum.sort()
    assert numbers == Enum.to_list(1..model.version)
    assert artifact.current_version == model.version
    assert artifact.state == :active == model.active

    if model.active do
      {:ok, version} = Library.version(artifact, nil)
      assert Library.page(version) == model.page

      for key <- ["k0", "k1", "k2"] do
        assert Storage.get(owner, id, :shared, key) == {:ok, Map.get(model.shared, key)}
        assert Storage.get(viewer, id, :shared, key) == {:ok, Map.get(model.shared, key)}

        assert Storage.get(owner, id, :personal, key) ==
                 {:ok, Map.get(model.personal, {:owner, key})}

        assert Storage.get(viewer, id, :personal, key) ==
                 {:ok, Map.get(model.personal, {:viewer, key})}
      end
    end

    :ok
  end
end
