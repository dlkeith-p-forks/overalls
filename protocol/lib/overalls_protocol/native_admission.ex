defmodule OverallsProtocol.NativeAdmission do
  @moduledoc "Reviewed immutable native image identities; checked independently of wire validation."

  alias OverallsProtocol.ImageManifest

  @manifest_file Path.expand("../../priv/native/freebsd-14.3.json", __DIR__)
  @external_resource @manifest_file
  @manifest @manifest_file |> File.read!() |> JSON.decode!()
  @image (case ImageManifest.validate(@manifest) do
            {:ok, image} -> image
            {:error, reason} -> raise "invalid reviewed native manifest: #{reason}"
          end)
  @bundle %{
    image_id: @image.id,
    architecture: :x86_64,
    boot_kind: :firmware,
    os: :freebsd,
    guest_agents: :freebsd_v1,
    pci: true,
    firmware_bytes: @manifest["boot"]["firmware"]["bytes"],
    kernel: @image.kernel
  }

  @doc "The production manifest whose exact bytes have recorded native acceptance evidence."
  @spec reviewed_manifest() :: map()
  def reviewed_manifest, do: @manifest

  # @cc [owner:ghuntley,label:security;protocol] native-admission-exact-reviewed-identity
  # A normalized native image or portable boot bundle MUST match the complete
  # reviewed immutable identity before admission or any guest capability is
  # granted. An agent-set name, positive kernel provenance, matching kernel
  # alone or retained stock catalog entry MUST NOT grant native admission.
  # Callers MUST first validate images/bundles through their versioned codecs;
  # nonnative validated identities retain their existing admission semantics.
  @spec admitted?(term()) :: boolean()
  def admitted?(%{guest_agents: agents} = identity) when agents in [:freebsd_v1, :illumos_v1],
    do: identity == @image or identity == @bundle

  def admitted?(%{guest_agents: agents}) when agents in [:linux, :none, :windows_v1], do: true
  def admitted?(_), do: false
end
