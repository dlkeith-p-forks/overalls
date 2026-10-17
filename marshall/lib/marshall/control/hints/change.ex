defmodule Marshall.Control.Hints.Change do
  @moduledoc """
  Ash change that emits a control hint from inside the action's transaction.

      changes do
        change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
          where: [action_is([:revoke])]
      end

  `from` names the attribute on the resulting record that holds the hinted
  identifier, or is `{module, function}` receiving the record. The hint is
  emitted in `after_action`, which runs inside the action's transaction, so it
  is delivered only if the action commits.
  """
  use Ash.Resource.Change

  alias Marshall.Control.Hints

  @impl true
  def init(options) do
    with {:ok, kind} when is_atom(kind) <- Keyword.fetch(options, :kind),
         true <- kind in Hints.kinds(),
         {:ok, from} <- Keyword.fetch(options, :from),
         true <-
           is_atom(from) or
             match?({module, function} when is_atom(module) and is_atom(function), from) do
      {:ok, options}
    else
      _ ->
        {:error, "Hints.Change needs a known :kind and a :from attribute or {module, function}"}
    end
  end

  @impl true
  def change(changeset, options, _context) do
    kind = Keyword.fetch!(options, :kind)
    from = Keyword.fetch!(options, :from)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      record |> identifier(from) |> then(&Hints.notify(kind, &1))
      {:ok, record}
    end)
  end

  # Only an after_action hook is added, which is valid for atomic actions too.
  @impl true
  def atomic(changeset, options, context), do: {:ok, change(changeset, options, context)}

  @spec identifier(Ash.Resource.Record.t(), atom() | {module(), atom()}) :: String.t() | nil
  defp identifier(record, {module, function}), do: apply(module, function, [record])
  defp identifier(record, attribute), do: Map.get(record, attribute)
end
