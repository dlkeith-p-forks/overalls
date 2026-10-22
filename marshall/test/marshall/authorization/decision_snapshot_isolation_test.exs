defmodule Marshall.Authorization.DecisionSnapshotIsolationTest do
  use Marshall.DataCase, async: false
  alias Ecto.Adapters.SQL
  alias Marshall.Authorization.DecisionSnapshot
  alias Marshall.Repo

  # The SQL sandbox owns the outer transaction and cannot change its isolation,
  # so these checks run on an unboxed connection. They only read, except for a
  # refused no-op update, so they leave no rows behind.
  setup do
    previous = Application.get_env(:marshall, :decision_snapshot_isolation)
    Application.put_env(:marshall, :decision_snapshot_isolation, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:marshall, :decision_snapshot_isolation),
        else: Application.put_env(:marshall, :decision_snapshot_isolation, previous)
    end)
  end

  # @cc [owner:ghuntley,label:verification;security] decision-snapshot-real-isolation
  # On a real connection the outermost decision batch MUST run repeatable-read
  # and read-only and memoize only inside the batch; a batch nested in another
  # transaction MUST keep that transaction's isolation and MUST NOT memoize.
  test "outermost batches are repeatable-read and read-only; nested batches do not memoize" do
    SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, {"repeatable read", "on", true}} =
               DecisionSnapshot.transaction(fn ->
                 {show("transaction_isolation"), show("transaction_read_only"),
                  DecisionSnapshot.active?()}
               end)

      refute DecisionSnapshot.active?()

      assert {:ok, {:ok, {"read committed", "off", false}}} =
               Repo.transaction(fn ->
                 DecisionSnapshot.transaction(fn ->
                   {show("transaction_isolation"), show("transaction_read_only"),
                    DecisionSnapshot.active?()}
                 end)
               end)

      error =
        assert_raise Postgrex.Error, fn ->
          DecisionSnapshot.transaction(fn ->
            SQL.query!(Repo, "UPDATE compute_virtual_machines SET name = name WHERE false", [])
          end)
        end

      assert error.postgres.code == :read_only_sql_transaction
      refute DecisionSnapshot.active?()
    end)
  end

  @spec show(String.t()) :: String.t()
  defp show(setting) do
    %{rows: [[value]]} = SQL.query!(Repo, "SHOW #{setting}", [])
    value
  end
end
