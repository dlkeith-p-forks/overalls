defmodule OverallsAntithesis.Lilly.ZFSIO do
  @moduledoc "The hosted controlled pool has no OpenZFS interval observation."
  alias Lilly.Host.Pool

  @spec sample([Pool.t()]) :: {:error, :zfs_io_unavailable}
  def sample(_pools), do: {:error, :zfs_io_unavailable}
end
