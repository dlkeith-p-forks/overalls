defmodule OverallsProtocol.EditorAssets do
  @moduledoc "Authenticated gateway declaration of its exact immutable editor asset release."
  alias OverallsProtocol.EditorRelease

  @spec request(term()) :: {:ok, map()} | {:error, :invalid_request}
  def request(
        %{
          "version" => 1,
          "editor_protocol" => protocol,
          "editor_commit" => commit,
          "editor_release" => release
        } = value
      )
      when map_size(value) == 4 do
    with {:ok, _} <-
           EditorRelease.decode(%{
             "protocol" => protocol,
             "commit" => commit,
             "release" => release
           }),
         do: {:ok, %{editor_protocol: protocol, editor_commit: commit, editor_release: release}},
         else: (_ -> {:error, :invalid_request})
  end

  def request(_), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:security;protocol] editor-assets-exact-acknowledgment
  # Asset acknowledgments MUST match the locally validated immutable release.
  # A gateway credential or a different release MUST NOT imply usable assets.
  @spec response(term(), EditorRelease.t()) :: {:ok, map()} | {:error, :invalid_message}
  def response(%{"version" => 1, "ready" => ready} = value, descriptor)
      when map_size(value) == 2 and is_map(ready) and map_size(ready) == 3 do
    with {:ok, fields} <- request(Map.put(ready, "version", 1)),
         true <-
           fields == %{
             editor_protocol: descriptor.protocol,
             editor_commit: descriptor.commit,
             editor_release: descriptor.release
           },
         do: {:ok, fields},
         else: (_ -> {:error, :invalid_message})
  end

  def response(_, _), do: {:error, :invalid_message}
end
