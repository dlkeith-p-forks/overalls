defmodule Marshall.Threads.TouchActivity do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _options, _context) do
    Ash.Changeset.atomic_update(changeset, :updated_at, {:atomic, Ash.Expr.expr(now())})
  end

  @impl true
  @spec atomic(Ash.Changeset.t(), keyword(), map()) :: {:ok, Ash.Changeset.t()}
  def atomic(changeset, options, context), do: {:ok, change(changeset, options, context)}
end
