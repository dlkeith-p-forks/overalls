defmodule Marshall.Artifacts.Limits do
  @moduledoc "Publish and version size limits, checked before anything is persisted."

  @page_bytes 16 * 1024 * 1024
  @publish_files 255
  @publish_bytes 64 * 1024 * 1024
  @version_files 511
  @version_bytes 256 * 1024 * 1024
  @inline_content_bytes 128 * 1024
  @storage_bytes 20 * 1024 * 1024
  @storage_key_bytes 256

  @type refusal ::
          :page_too_large | :too_many_files | :publish_too_large | :version_too_large

  @spec page_bytes() :: pos_integer()
  def page_bytes, do: @page_bytes
  @spec publish_files() :: pos_integer()
  def publish_files, do: @publish_files
  @spec publish_bytes() :: pos_integer()
  def publish_bytes, do: @publish_bytes
  @spec version_files() :: pos_integer()
  def version_files, do: @version_files
  @spec version_bytes() :: pos_integer()
  def version_bytes, do: @version_bytes
  @spec inline_content_bytes() :: pos_integer()
  def inline_content_bytes, do: @inline_content_bytes
  @spec storage_bytes() :: pos_integer()
  def storage_bytes, do: @storage_bytes
  @spec storage_key_bytes() :: pos_integer()
  def storage_key_bytes, do: @storage_key_bytes

  # @cc [owner:ghuntley,label:capacity] artifact-limits-before-persist
  # A publish MUST be refused before any blob or version row is written when
  # the page exceeds 16 MiB, the files it sends exceed 255 or 64 MiB, or the
  # resulting version exceeds 511 files or 256 MiB. Limits are inclusive.
  @spec check(%{
          page_bytes: non_neg_integer(),
          publish_files: non_neg_integer(),
          publish_bytes: non_neg_integer(),
          version_files: non_neg_integer(),
          version_bytes: non_neg_integer()
        }) :: :ok | {:error, refusal()}
  def check(totals) do
    cond do
      totals.page_bytes > @page_bytes -> {:error, :page_too_large}
      totals.publish_files > @publish_files -> {:error, :too_many_files}
      totals.publish_bytes > @publish_bytes -> {:error, :publish_too_large}
      totals.version_files > @version_files -> {:error, :too_many_files}
      totals.version_bytes > @version_bytes -> {:error, :version_too_large}
      true -> :ok
    end
  end
end
