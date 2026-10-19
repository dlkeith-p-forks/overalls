defmodule Susan.Audit.Chain do
  @moduledoc """
  Pure hash-chain arithmetic for audit rows.

  `digest = SHA-256("susan.audit.v1" || prev_digest || canonical fields)`,
  hex-encoded, where canonical fields are newline-separated in a fixed order
  with absent values empty and the timestamp in Unix microseconds. The first
  row ever appended chains to sixty-four zeros.
  """

  @genesis String.duplicate("0", 64)
  @fields [
    :action,
    :reason,
    :install_fingerprint,
    :key_id,
    :provider,
    :outcome,
    :delivery_id,
    :keyring_id,
    :count,
    :occurred_at
  ]

  @type entry :: %{
          required(:action) => atom(),
          required(:outcome) => atom(),
          required(:occurred_at) => DateTime.t(),
          optional(atom()) => term()
        }
  @type row :: %{
          required(:prev_digest) => String.t(),
          required(:digest) => String.t(),
          optional(atom()) => term()
        }

  @spec genesis() :: String.t()
  def genesis, do: @genesis

  @spec fields() :: [atom()]
  def fields, do: @fields

  # @cc [owner:ghuntley,label:security] susan-audit-hash-chain
  # A row digest MUST cover every recorded field and its predecessor's digest,
  # so editing, reordering or deleting an interior row is detectable by
  # verify/1. Only a prefix may be removed (retention), which verify/1 accepts
  # by starting from the first remaining row.
  @spec digest(String.t(), entry()) :: String.t()
  def digest(prev, entry) when is_binary(prev) do
    canonical = Enum.map_join(@fields, "\n", &field(Map.get(entry, &1)))

    :crypto.hash(:sha256, ["susan.audit.v1\n", prev, "\n", canonical])
    |> Base.encode16(case: :lower)
  end

  @doc "Verifies an ordered list of rows: each links to its predecessor and matches its digest."
  @spec verify([row()]) :: :ok | {:error, {:broken_at, non_neg_integer()}}
  def verify(rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {row, index}, previous ->
      linked = previous == nil or row.prev_digest == previous
      intact = digest(row.prev_digest, row) == row.digest

      if linked and intact,
        do: {:cont, row.digest},
        else: {:halt, {:error, {:broken_at, index}}}
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp field(nil), do: ""
  defp field(%DateTime{} = at), do: Integer.to_string(DateTime.to_unix(at, :microsecond))
  defp field(value) when is_atom(value), do: Atom.to_string(value)
  defp field(value) when is_integer(value), do: Integer.to_string(value)
  defp field(value) when is_binary(value), do: value
end
