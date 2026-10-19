defmodule OverallsProtocol.NativeAdmission do
  @moduledoc "Reviewed immutable native image identities; checked independently of wire validation."

  alias OverallsProtocol.ImageManifest

  @selected_files %{
    freebsd: Path.expand("../../priv/native/freebsd-14.3.json", __DIR__),
    illumos: Path.expand("../../priv/native/omnios-r151050.json", __DIR__)
  }
  @history_files %{
    freebsd: [Path.expand("../../priv/native/freebsd-14.3.json", __DIR__)],
    illumos: [Path.expand("../../priv/native/omnios-r151050.json", __DIR__)]
  }
  for path <- Enum.uniq(Map.values(@selected_files) ++ List.flatten(Map.values(@history_files))) do
    @external_resource path
  end

  @history Map.new(@history_files, fn {os, paths} ->
             images =
               Enum.map(paths, fn path ->
                 case path |> File.read!() |> JSON.decode!() |> ImageManifest.validate() do
                   {:ok, %{os: ^os, manifest: %{"version" => 6}} = image} -> image
                   _ -> raise "invalid reviewed native history for #{os}"
                 end
               end)

             ids = Enum.map(images, & &1.id)

             if images == [] or Enum.uniq(ids) != ids,
               do: raise("empty or duplicate reviewed native history for #{os}")

             {os, images}
           end)
  @manifests Map.new(@selected_files, fn {os, path} ->
               manifest = path |> File.read!() |> JSON.decode!()

               unless Enum.any?(Map.fetch!(@history, os), &(&1.manifest == manifest)),
                 do: raise("selected native image is absent from reviewed history for #{os}")

               {os, manifest}
             end)
  @images Enum.flat_map(Map.values(@history), & &1)
  @bundles Enum.map(@images, fn image ->
             bundle = %{
               image_id: image.id,
               architecture: image.architecture,
               boot_kind: image.boot_kind,
               os: image.os,
               guest_agents: image.guest_agents,
               pci: image.pci,
               firmware_bytes: image.manifest["boot"]["firmware"]["bytes"],
               kernel: image.kernel
             }

             if Map.get(image, :git_identity_version) == 1,
               do: Map.put(bundle, :git_identity_version, 1),
               else: bundle
           end)
  @reviewed_identities @images ++ @bundles

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-native-qualification-is-independent
  # Snapshot continuation MUST require separately recorded exact native image
  # qualification. Cold-boot admission or a candidate kernel test alone MUST NOT
  # grant pause/resume to firmware guests. Only the qualified Linux kernel/device
  # path is enabled until immutable native artifacts receive acceptance evidence.
  @spec checkpoint_admitted?(term()) :: boolean()
  def checkpoint_admitted?(%{guest_agents: :linux, boot_kind: :kernel}), do: true
  def checkpoint_admitted?(_), do: false

  @doc "The production manifest whose exact bytes have recorded native acceptance evidence."
  @spec reviewed_manifest() :: map()
  def reviewed_manifest, do: reviewed_manifest(:freebsd)

  @doc "The exact reviewed production manifest for the selected native OS family."
  @spec reviewed_manifest(:freebsd | :illumos) :: map()
  def reviewed_manifest(os) when os in [:freebsd, :illumos], do: Map.fetch!(@manifests, os)

  # @cc [owner:ghuntley,label:security;recovery] native-admission-retained-history
  # Selected defaults MUST belong to explicit immutable reviewed history. Changing
  # selection MUST NOT remove previously admitted image or portable-bundle
  # identities needed by retained machines; adding a file alone grants no admission.
  @spec reviewed_manifests(:freebsd | :illumos) :: [map()]
  def reviewed_manifests(os) when os in [:freebsd, :illumos],
    do: Enum.map(Map.fetch!(@history, os), & &1.manifest)

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
