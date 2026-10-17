defmodule Lilly.Lifecycle.Provisioning do
  @moduledoc "Provisioning progress and exact-boot readiness; never physical launch authority."
  use Lilly.Lifecycle.Resource,
    initial: [:pending],
    edges: [
      pending: [:materializing, :failed, :superseded],
      materializing: [:launching, :failed, :superseded],
      launching: [:awaiting_trust, :failed, :superseded],
      awaiting_trust: [:awaiting_ssh, :unattested, :failed, :superseded],
      awaiting_ssh: [:ready, :failed, :superseded],
      unattested: [:failed, :superseded],
      ready: [:superseded],
      failed: [:superseded],
      superseded: [:pending]
    ]

  @fields ~w(state host_id placement_id execution_epoch generation started_at launched_at deadline boot_challenge boot_id)
  @identity ~w(host_id placement_id execution_epoch generation started_at)
  @maximum 253_402_300_800_000

  # @cc [owner:ghuntley,label:security;recovery] provisioning-bound-proof
  # Launched records MUST have a bounded immutable deadline and exact execution
  # binding. Launch requires a challenge; ready requires a guest boot UUID; the
  # agentless `unattested` phase carries a challenge and never a boot UUID and
  # cannot become ready. Earlier phases cannot contain a ready receipt. No
  # diagnostics expose nonce bytes. Physical ownership remains the driver's
  # independent responsibility.
  def valid_payload?(payload) do
    Enum.sort(Map.keys(payload)) == Enum.sort(@fields) and
      Enum.all?(~w(host_id placement_id), &OverallsProtocol.uuid?(payload[&1])) and
      Enum.all?(~w(execution_epoch generation), &positive?(payload[&1])) and
      is_integer(payload["started_at"]) and payload["started_at"] in 1..@maximum and
      deadline?(payload) and
      proof?(payload)
  end

  # @cc [owner:ghuntley,label:recovery] provisioning-no-deadline-reset
  # A generation MUST retain its identity, deadline and established boot nonce.
  # Only explicit supersession followed by a strictly newer execution can reset
  # progress. Duplicate writes are idempotent and never append audit events.
  def valid_transition?(nil, next), do: next["state"] == "pending"

  def valid_transition?(previous, %{"state" => "pending"} = next) do
    previous["state"] == "superseded" and
      Map.take(previous, ~w(host_id placement_id)) == Map.take(next, ~w(host_id placement_id)) and
      revision(next) > revision(previous)
  end

  def valid_transition?(previous, next) do
    Map.take(previous, @identity) == Map.take(next, @identity) and
      (is_nil(previous["deadline"]) or
         Map.take(previous, ~w(launched_at deadline)) == Map.take(next, ~w(launched_at deadline))) and
      (previous["boot_challenge"] == nil or
         previous["boot_challenge"] == next["boot_challenge"]) and
      (previous["boot_id"] == nil or previous["boot_id"] == next["boot_id"]) and
      (next["state"] != "ready" or next["deadline"] > System.system_time(:millisecond))
  end

  defp deadline?(%{"launched_at" => nil, "deadline" => nil} = value),
    do: value["state"] in ~w(pending materializing failed superseded)

  defp deadline?(value) do
    value["state"] not in ~w(pending materializing) and
      is_integer(value["launched_at"]) and value["launched_at"] >= value["started_at"] and
      is_integer(value["deadline"]) and value["deadline"] < @maximum and
      (value["deadline"] - value["launched_at"]) in 1..2_400_000
  end

  defp proof?(%{"state" => state, "boot_challenge" => nonce, "boot_id" => boot}) do
    case state do
      state when state in ~w(pending materializing) ->
        is_nil(nonce) and is_nil(boot)

      state when state in ~w(launching awaiting_trust awaiting_ssh unattested) ->
        nonce?(nonce) and is_nil(boot)

      "ready" ->
        nonce?(nonce) and OverallsProtocol.uuid?(boot)

      state when state in ~w(failed superseded) ->
        (is_nil(nonce) and is_nil(boot)) or
          (nonce?(nonce) and (is_nil(boot) or OverallsProtocol.uuid?(boot)))

      _ ->
        false
    end
  end

  defp nonce?(nonce), do: is_binary(nonce) and Regex.match?(~r/\A[0-9a-f]{64}\z/, nonce)
  defp positive?(value), do: is_integer(value) and value in 1..9_223_372_036_854_775_807
  defp revision(payload), do: {payload["execution_epoch"], payload["generation"]}
end
