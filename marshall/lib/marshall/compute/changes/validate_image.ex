defmodule Marshall.Compute.Changes.ValidateImage do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case OverallsProtocol.ImageManifest.validate(
           Ash.Changeset.get_attribute(changeset, :manifest)
         ) do
      {:ok, image} ->
        Ash.Changeset.force_change_attributes(
          changeset,
          Map.take(image, [:id, :architecture, :minimum_memory_bytes, :minimum_disk_bytes])
        )

      _ ->
        Ash.Changeset.add_error(changeset, field: :manifest, message: "invalid image manifest")
    end
  end
end
