defmodule OverallsProtocol.NativeAdmission do
  @moduledoc "Reviewed immutable native image identities; checked independently of wire validation."

  alias OverallsProtocol.ImageManifest

  @freebsd_manifest_file Path.expand("../../priv/native/freebsd-14.3.json", __DIR__)
  @illumos_manifest_file Path.expand("../../priv/native/omnios-r151050.json", __DIR__)
  @external_resource @freebsd_manifest_file
  @external_resource @illumos_manifest_file
  @manifests %{
    freebsd: @freebsd_manifest_file |> File.read!() |> JSON.decode!(),
    illumos: @illumos_manifest_file |> File.read!() |> JSON.decode!()
  }
  @images Map.new(@manifests, fn {os, manifest} ->
            case ImageManifest.validate(manifest) do
              {:ok, %{os: ^os} = image} -> {os, image}
              _ -> raise "invalid reviewed native manifest for #{os}"
            end
          end)
  @bundles Map.new(@images, fn {os, image} ->
             {os,
              %{
                image_id: image.id,
                architecture: image.architecture,
                boot_kind: image.boot_kind,
                os: image.os,
                guest_agents: image.guest_agents,
                pci: image.pci,
                firmware_bytes: image.manifest["boot"]["firmware"]["bytes"],
                kernel: image.kernel
              }}
           end)
  @reviewed_identities Map.values(@images) ++ Map.values(@bundles)

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-native-qualification-is-independent
  # Memory continuation MUST require a validated Linux kernel identity whose exact
  # content-addressed image ID appears in the trusted local qualification list.
  # Missing qualification MUST refuse; cold-boot admission grants no continuation.
  # Callers MUST validate identities through ImageManifest or WorkloadBundle first.
  @spec checkpoint_admitted?(term(), [String.t()]) :: boolean()
  def checkpoint_admitted?(identity, qualified_image_ids \\ [])

  def checkpoint_admitted?(%{guest_agents: :linux, boot_kind: :kernel} = identity, ids)
      when is_list(ids) do
    id = Map.get(identity, :image_id, Map.get(identity, :id))
    checkpoint_qualified?(id, ids)
  end

  def checkpoint_admitted?(_, _), do: false

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-reported-qualification-exact
  # Qualification MUST bind an exact canonical image ID in a bounded distinct
  # trusted list. Missing/invalid lists MUST refuse; qualifying supersets remain valid.
  @spec checkpoint_qualified?(term(), term()) :: boolean()
  def checkpoint_qualified?(image_id, ids),
    do: ImageManifest.id?(image_id) and checkpoint_image_ids?(ids) and image_id in ids

  @spec checkpoint_image_ids?(term()) :: boolean()
  def checkpoint_image_ids?(ids) when is_list(ids) and length(ids) <= 256,
    do: Enum.all?(ids, &ImageManifest.id?/1) and Enum.uniq(ids) == ids

  def checkpoint_image_ids?(_), do: false

  @doc "The production manifest whose exact bytes have recorded native acceptance evidence."
  @spec reviewed_manifest() :: map()
  def reviewed_manifest, do: reviewed_manifest(:freebsd)

  @doc "The exact reviewed production manifest for the selected native OS family."
  @spec reviewed_manifest(:freebsd | :illumos) :: map()
  def reviewed_manifest(os) when os in [:freebsd, :illumos], do: Map.fetch!(@manifests, os)

  # @cc [owner:ghuntley,label:security;protocol] native-admission-exact-reviewed-identity
  # A normalized native image or portable boot bundle MUST match the complete
  # reviewed immutable identity before admission or any guest capability is
  # granted. An agent-set name, positive kernel provenance, matching kernel
  # alone or retained stock catalog entry MUST NOT grant native admission.
  # Callers MUST first validate images/bundles through their versioned codecs;
  # nonnative validated identities retain their existing admission semantics.
  @spec admitted?(term()) :: boolean()
  def admitted?(%{guest_agents: agents} = identity) when agents in [:freebsd_v1, :illumos_v1],
    do: identity in @reviewed_identities

  def admitted?(%{guest_agents: agents})
      when agents in [:linux, :none, :windows_v1, :windows_editor_v1],
      do: true

  def admitted?(_), do: false
end
