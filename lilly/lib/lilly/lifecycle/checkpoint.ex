defmodule Lilly.Lifecycle.Checkpoint do
  @moduledoc "Single-use RAM continuation authority, separate from portable checkpoint bytes."
  use Lilly.Lifecycle.Resource,
    initial: [:empty],
    edges: [
      empty: [:empty, :receiving, :capturing, :retired],
      receiving: [:receiving, :ready, :retired],
      capturing: [:capturing, :copied, :retired],
      copied: [:copied, :ready, :retired],
      ready: [:ready, :restoring, :retired],
      restoring: [:restoring, :consumed, :retired],
      consumed: [:consumed, :capturing, :retired],
      retired: [:retired, :empty]
    ]

  @spec valid_payload?(map()) :: boolean()
  def valid_payload?(value), do: Lilly.VM.Checkpoint.valid_record?(value)

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-restore-is-single-use
  # A restoring/consumed checkpoint MUST NOT return to ready or change restore
  # authority. A subsequent capture MUST have a different checkpoint UUID.
  @spec valid_transition?(map() | nil, map()) :: boolean()
  def valid_transition?(nil, _next), do: true

  def valid_transition?(previous, next) do
    same_binding = previous["binding"] == next["binding"]

    empty_rebind =
      previous["phase"] == "empty" and next["phase"] == "empty" and
        previous["slots"] == %{} and next["slots"] == %{} and
        Map.delete(previous["binding"], "workload") == Map.delete(next["binding"], "workload")

    same_attempt = previous["restore_authority"] == next["restore_authority"]
    same_checkpoint = previous["checkpoint_id"] == next["checkpoint_id"]
    same_capture = previous["capture_authority"] == next["capture_authority"]
    same_manifest = is_nil(previous["manifest"]) or previous["manifest"] == next["manifest"]

    same_descriptor =
      is_nil(previous["descriptor"]) or previous["descriptor"] == next["descriptor"]

    same_slot = previous["slot"] == next["slot"]

    (same_binding or empty_rebind) and
      cond do
        previous["phase"] == "retired" and next["phase"] == "empty" ->
          true

        previous["phase"] == "empty" and next["phase"] == "receiving" ->
          not same_checkpoint and slots_advance?(previous["slots"], next["slots"])

        next["phase"] == "capturing" and previous["phase"] != "capturing" ->
          not same_checkpoint and slots_advance?(previous["slots"], next["slots"])

        next["phase"] == "retired" ->
          same_checkpoint and same_capture and same_attempt and same_manifest and same_descriptor and
            same_slot and
            previous["slots"] == next["slots"]

        previous["phase"] in ["restoring", "consumed"] ->
          same_attempt and same_checkpoint and same_capture and same_manifest and same_descriptor and
            same_slot and slots_advance?(previous["slots"], next["slots"])

        true ->
          same_checkpoint and same_capture and same_manifest and same_descriptor and same_slot and
            slots_advance?(previous["slots"], next["slots"])
      end
  end

  defp slots_advance?(previous, next) do
    Enum.all?(previous, fn {slot, leaf} ->
      case next[slot] do
        nil ->
          leaf["state"] == "retiring"

        candidate ->
          leaf["nonce"] == candidate["nonce"] and
            Enum.all?(~w(dataset_guid snapshot_guid checkpoint_id), fn key ->
              is_nil(leaf[key]) or leaf[key] == candidate[key]
            end) and
            candidate["state"] in case leaf["state"] do
              "creating" -> ["creating", "empty", "sealed"]
              "empty" -> ["empty", "sealed"]
              "sealed" -> ["sealed", "retiring"]
              "retiring" -> ["retiring"]
            end
      end
    end)
  end
end
