defmodule OverallsProtocol.EditorRelease do
  @moduledoc "Content-bound editor package identity; missing capabilities never imply editor support."
  @type t :: %{protocol: 1, commit: String.t(), release: String.t()}

  # @cc [owner:ghuntley,label:protocol;security] editor-release-closed-identity
  # Editor capabilities MUST carry the exact reviewed protocol, source commit and
  # patched package release digest. Unknown fields, versions and missing digests fail.
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_editor_release}
  def decode(%{"protocol" => 1, "commit" => commit, "release" => release} = value)
      when map_size(value) == 3 do
    if digest?(commit, 40) and digest?(release, 64),
      do: {:ok, %{protocol: 1, commit: commit, release: release}},
      else: {:error, :invalid_editor_release}
  end

  def decode(_), do: {:error, :invalid_editor_release}

  @spec digest?(term(), 32 | 40 | 64) :: boolean()
  def digest?(value, size) when is_binary(value) and byte_size(value) == size,
    do: Regex.match?(~r/\A[0-9a-f]+\z/, value)

  def digest?(_, _), do: false
end
