defmodule Marshall.Artifacts.Audit do
  @moduledoc "Same-transaction artifact receipts. Audit failure fails the mutation."
  alias Marshall.Artifacts.AuditEvent
  alias Marshall.Compute.Ledger

  @type via :: :agent | :web | :admin | :content | :system
  @type attrs :: %{
          required(:kind) => atom(),
          required(:via) => via(),
          optional(:artifact_id) => String.t() | nil,
          optional(:actor_id) => String.t() | nil,
          optional(:reason) => atom() | nil,
          optional(:version) => non_neg_integer() | nil,
          optional(:bytes) => non_neg_integer() | nil
        }

  @spec record!(attrs()) :: AuditEvent.t()
  def record!(attrs) do
    reason = if attrs[:reason] in AuditEvent.reasons(), do: attrs[:reason]
    Ledger.create!(AuditEvent, :record, Map.put(attrs, :reason, reason))
  end

  @doc "Records a refusal in its own transaction, after the refused work rolled back."
  @spec refusal(attrs()) :: :ok
  def refusal(attrs) do
    {:ok, _} = Ledger.transaction(fn -> record!(attrs) end, {:system, nil})
    :ok
  end
end
