defmodule Susan.Audit.Log do
  @moduledoc """
  Appending, verifying, exporting and pruning Susan's audit trail.

  Appends take a transaction-scoped advisory lock, so the chain is linear even
  with concurrent requests. The prune deletes only rows older than 90 days,
  inside a transaction that sets the `susan.audit_prune` guard the database
  trigger requires, and appends its own `prune` entry in the same transaction.
  """
  require Ash.Query
  require Susan.Events
  alias Susan.Audit.{AuditEntry, Chain}
  alias Susan.Repo

  @lock 0x5375_7361_6E00
  @retention_days 90

  @type action ::
          :key_issued
          | :key_rotated
          | :key_denylisted
          | :poke_accepted
          | :poke_rejected
          | :rate_limited
          | :provider_sent
          | :provider_failed
          | :provider_unregistered
          | :install_first_seen
          | :install_blocked
          | :prune
          | :admin
  @type fields :: %{
          optional(:reason) => atom(),
          optional(:install_fingerprint) => String.t(),
          optional(:key_id) => String.t(),
          optional(:provider) => :apns | :fcm | :wns,
          optional(:delivery_id) => String.t(),
          optional(:keyring_id) => 1..255,
          optional(:count) => non_neg_integer()
        }

  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @spec append(action(), :ok | :refused | :failed, fields()) :: {:ok, AuditEntry.t()} | :error
  def append(action, outcome, fields \\ %{}) when is_atom(action) and is_map(fields) do
    case transaction(action, fn -> do_append(action, outcome, fields) end) do
      {:ok, entry} -> {:ok, entry}
      :error -> :error
    end
  end

  # @cc [owner:ghuntley,label:security] susan-audited-mutation-atomic
  # Mandatory audit appends and their database mutations MUST commit together.
  # Nested transactions MUST NOT emit a committed audit success before the
  # caller's outer transaction completes.
  @spec transaction(action(), (-> {:ok, result} | :error | {:error, term()})) ::
          {:ok, result} | :error
        when result: term()
  def transaction(action, fun) when is_function(fun, 0) do
    nested? = Repo.in_transaction?()

    result =
      Repo.transaction(fn ->
        case fun.() do
          {:ok, value} -> value
          _ -> Repo.rollback(:audit_operation_failed)
        end
      end)

    case result do
      {:ok, value} ->
        unless nested? or value == :existing,
          do: Susan.Events.emit("susan.audit_appended", action: action)

        {:ok, value}

      _ ->
        Susan.Events.emit("susan.audit_append_failed", action: action)
        :error
    end
  rescue
    _ ->
      Susan.Events.emit("susan.audit_append_failed", action: action)
      :error
  end

  @doc "Append inside an existing transaction without emitting a premature success."
  @spec append_in_transaction(action(), :ok | :refused | :failed, fields()) ::
          {:ok, AuditEntry.t()} | :error
  def append_in_transaction(action, outcome, fields) do
    if Repo.in_transaction?(), do: do_append(action, outcome, fields), else: :error
  end

  defp do_append(action, outcome, fields) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock])

    prev =
      case Repo.query!("SELECT digest FROM audit_entries ORDER BY seq DESC LIMIT 1", []) do
        %{rows: [[digest]]} -> digest
        %{rows: []} -> Chain.genesis()
      end

    entry =
      fields
      |> Map.take(Chain.fields())
      |> Map.merge(%{
        action: action,
        outcome: outcome,
        occurred_at: DateTime.utc_now()
      })

    attributes = Map.merge(entry, %{prev_digest: prev, digest: Chain.digest(prev, entry)})

    case Ash.create(AuditEntry, attributes, action: :append) do
      {:ok, created} -> {:ok, created}
      {:error, _} -> :error
    end
  end

  # @cc [owner:ghuntley,label:recovery] susan-receipt-audit-repair
  # A persisted terminal delivery receipt MUST permit idempotent audit repair
  # without another provider send. Repairs MUST serialize with ordinary appends.
  @spec reconcile_receipt(Susan.Relay.DeliveryReceipt.t(), fields()) :: :ok | :error
  def reconcile_receipt(receipt, fields \\ %{}) do
    {action, outcome} =
      case receipt.status do
        :sent -> {:provider_sent, :ok}
        :unregistered -> {:provider_unregistered, :refused}
        :failed -> {:provider_failed, :failed}
      end

    case transaction(action, fn ->
           Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock])

           existing =
             AuditEntry
             |> Ash.Query.filter(
               action == ^action and delivery_id == ^receipt.delivery_id and
                 install_fingerprint == ^receipt.install_fingerprint
             )
             |> Ash.Query.limit(1)
             |> Ash.read!()

           case existing do
             [_] ->
               {:ok, :existing}

             [] ->
               do_append(
                 action,
                 outcome,
                 Map.merge(fields, %{
                   delivery_id: receipt.delivery_id,
                   install_fingerprint: receipt.install_fingerprint
                 })
               )
           end
         end) do
      {:ok, _} -> :ok
      :error -> :error
    end
  end

  @doc "Repair terminal receipt audit records in bounded batches before retention removes evidence."
  @spec reconcile_receipts() :: :ok | :error
  def reconcile_receipts, do: reconcile_after("00000000-0000-0000-0000-000000000000")

  @spec reconcile_after(String.t()) :: :ok | :error
  defp reconcile_after(after_id) do
    rows =
      Susan.Relay.DeliveryReceipt
      |> Ash.Query.filter(id > ^after_id and status in [:sent, :unregistered, :failed])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(100)
      |> Ash.read!()

    cond do
      rows == [] -> :ok
      Enum.all?(rows, &(reconcile_receipt(&1) == :ok)) -> reconcile_after(List.last(rows).id)
      true -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Reads entries in chain order, optionally only those with seq greater than `after`."
  @spec read(non_neg_integer(), pos_integer()) :: [AuditEntry.t()]
  def read(after_seq \\ 0, limit \\ 1000) when is_integer(after_seq) and is_integer(limit) do
    AuditEntry
    |> Ash.Query.for_read(:chronological)
    |> Ash.Query.filter(seq > ^after_seq)
    |> Ash.Query.limit(min(limit, 10_000))
    |> Ash.read!()
  end

  @doc "Read the newest entries, returned in chronological order."
  @spec tail(pos_integer()) :: [AuditEntry.t()]
  def tail(limit) when limit in 1..10_000 do
    AuditEntry
    |> Ash.Query.sort(seq: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
    |> Enum.reverse()
  end

  @doc "Stream entries through the current highest sequence; concurrent retention may remove rows."
  @spec stream() :: Enumerable.t()
  def stream do
    upper =
      case tail(1) do
        [] -> 0
        [entry] -> entry.seq
      end

    Stream.resource(
      fn -> 0 end,
      fn
        after_seq when after_seq >= upper ->
          {:halt, after_seq}

        after_seq ->
          rows = read(after_seq, 1000) |> Enum.take_while(&(&1.seq <= upper))

          case rows do
            [] -> {:halt, upper}
            _ -> {rows, List.last(rows).seq}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc "Verifies the whole remaining chain."
  @spec verify() :: :ok | {:error, {:broken_at, non_neg_integer()}}
  def verify,
    do: AuditEntry |> Ash.Query.for_read(:chronological) |> Ash.read!() |> Chain.verify()

  @doc "One JSON object per entry, in chain order."
  @spec export_lines([AuditEntry.t()]) :: [String.t()]
  def export_lines(entries) do
    Enum.map(entries, fn entry ->
      entry
      |> Map.take([:seq, :prev_digest, :digest | Chain.fields()])
      |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
      |> JSON.encode!()
    end)
  end

  # @cc [owner:ghuntley,label:privacy;security] susan-audit-retention-prune
  # The prune MUST delete only entries older than 90 days, MUST run inside
  # the transaction-local susan.audit_prune guard the trigger requires, and
  # MUST append its own prune entry with the deleted count in that same
  # transaction, so a prune is never silent.
  @spec prune(DateTime.t()) :: {:ok, non_neg_integer()} | :error
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)

    nested? = Repo.in_transaction?()

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock])
        Repo.query!("SELECT set_config('susan.audit_prune', 'on', true)", [])

        %{num_rows: count} =
          Repo.query!("DELETE FROM audit_entries WHERE occurred_at < $1", [cutoff])

        Repo.query!("SELECT set_config('susan.audit_prune', 'off', true)", [])

        case do_append(:prune, :ok, %{reason: :retention, count: count}) do
          {:ok, _} -> count
          :error -> Repo.rollback(:append_failed)
        end
      end)

    case result do
      {:ok, count} ->
        unless nested?, do: Susan.Events.emit("susan.audit_pruned", count: count)
        {:ok, count}

      _ ->
        Susan.Events.emit("susan.audit_append_failed", action: :prune)
        :error
    end
  end
end
