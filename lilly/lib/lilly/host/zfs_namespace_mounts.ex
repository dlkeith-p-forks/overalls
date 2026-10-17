defmodule Lilly.Host.ZFSNamespaceMounts do
  @moduledoc "Detach only exact claimed ZFS mount copies retained by other mount namespaces."
  alias Lilly.Host.Command

  # @cc [owner:ghuntley,label:security;recovery] namespace-cleanup-only-after-fence
  # detach/2 MUST be called only while the host lock is held, after physical VM
  # stop, ownership/GUID verification and the durable deleting fence. The native
  # helper rechecks every namespace before ordinary unmount. Any busy, unknown or
  # detected raced mount prevents the enclosing deletion from releasing capacity.
  @spec detach(String.t(), Path.t()) ::
          {:ok, non_neg_integer()} | {:error, :busy | :unconfirmed}
  def detach(dataset, path) do
    case Command.run(:zfs_namespace_unmount, [dataset, path], 30_000) do
      {:ok, "cleaned " <> value} ->
        case Integer.parse(String.trim(value)) do
          {count, ""} when count in 0..512 -> {:ok, count}
          _ -> {:error, :unconfirmed}
        end

      {:ok, "busy\n"} ->
        {:error, :busy}

      _ ->
        {:error, :unconfirmed}
    end
  end
end
