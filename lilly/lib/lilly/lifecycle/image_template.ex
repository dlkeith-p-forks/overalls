defmodule Lilly.Lifecycle.ImageTemplate do
  @moduledoc "One sealed image incarnation; deletion is terminal and never VM authority."
  use Lilly.Lifecycle.Resource,
    initial: [:staging],
    edges: [
      staging: [:verifying, :quarantined, :retiring],
      verifying: [:sealing, :quarantined, :retiring],
      sealing: [:ready, :quarantined, :retiring],
      ready: [:quarantined, :retiring],
      quarantined: [:retiring],
      retiring: [:deleted],
      deleted: []
    ]

  @fields ~w(state host_id pool_id image_id incarnation nonce guid bytes identities)
  @binding ~w(host_id pool_id image_id incarnation nonce bytes)
  # ADR-0098 permits 128 GiB root + two 8 GiB boot artifacts. Image.load/1
  # additionally admits a manifest up to 16 KiB, which also consumes the budget.
  @maximum_bytes 128 * 1024 ** 3 + 2 * 8 * 1024 ** 3 + 16_384

  # @cc [owner:ghuntley,label:security;recovery] template-incarnation-proof
  # Publication MUST bind a closed incarnation to host/pool/image, immutable size
  # and creation nonce. Sealing/ready require exact file identities. A bound GUID
  # or identity cannot change; deleted incarnations cannot be reused.
  def valid_payload?(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@fields) and
      Enum.all?(~w(host_id pool_id incarnation), &OverallsProtocol.uuid?(value[&1])) and
      OverallsProtocol.ImageManifest.id?(value["image_id"]) and
      is_binary(value["nonce"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value["nonce"]) and
      is_integer(value["bytes"]) and value["bytes"] in 1..@maximum_bytes and
      (is_nil(value["guid"]) or guid?(value["guid"])) and
      identities?(value["identities"]) and
      (value["state"] not in ~w(verifying sealing ready) or guid?(value["guid"])) and
      (value["state"] not in ~w(sealing ready) or map_size(value["identities"]) in [3, 4])
  end

  def valid_transition?(nil, next), do: next["state"] == "staging"

  def valid_transition?(previous, next) do
    Map.take(previous, @binding) == Map.take(next, @binding) and
      (is_nil(previous["guid"]) or previous["guid"] == next["guid"]) and
      (previous["identities"] == %{} or previous["identities"] == next["identities"])
  end

  defp guid?(value),
    do: is_binary(value) and Regex.match?(~r/\A[1-9][0-9]{0,19}\z/, value)

  defp identities?(value) when value == %{}, do: true

  # @cc [owner:ghuntley,label:recovery;security] template-record-outlives-image-kind
  # A record MUST stay decodable after its image kind leaves
  # ImageManifest.file_sets/0, so one stale incarnation can be retired and
  # never makes the pool's catalog unreadable. Identities therefore name 2-4
  # artifacts including manifest.json, each a single lower-case path component
  # starting with a letter or digit (never `.`, `..` or containing `/`); the
  # reader, not the record, refuses a kind this release cannot verify.
  defp identities?(value) when is_map(value) do
    map_size(value) in 2..4 and Map.has_key?(value, "manifest.json") and
      Enum.all?(Map.keys(value), &artifact_name?/1) and
      Enum.all?(value, fn {_, identity} ->
        is_list(identity) and length(identity) == 11 and
          Enum.all?(identity, &(is_integer(&1) and &1 >= 0))
      end)
  end

  defp identities?(_), do: false

  defp artifact_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/, name)
end
