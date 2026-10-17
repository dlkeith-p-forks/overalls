defmodule Marshall.CommittedFixtureInventory do
  @moduledoc "Independent complete-row oracle for exclusively running committed test fixtures."
  alias Marshall.Repo
  import ExUnit.Assertions, only: [assert: 2]

  @type t :: %{String.t() => [String.t()]}
  @type difference :: %{
          String.t() => %{
            before?: boolean(),
            after?: boolean(),
            added: [String.t()],
            removed: [String.t()]
          }
        }

  # @cc [owner:ghuntley,label:verification] committed-fixture-inventory-diagnostics
  # Equality MUST include empty tables and duplicate row hashes. On mismatch,
  # diagnostics MUST report every changed table and added/removed hash without
  # row payloads or truncation hiding the changed table.
  @spec assert_restored!(t()) :: :ok
  def assert_restored!(before) do
    current = snapshot()

    assert current == before,
           "Committed fixture inventory changed: " <>
             inspect(difference(before, current), limit: :infinity, printable_limit: :infinity)

    :ok
  end

  @spec difference(t(), t()) :: difference()
  def difference(before, current) do
    for table <- Enum.uniq(Map.keys(before) ++ Map.keys(current)),
        Map.fetch(before, table) != Map.fetch(current, table),
        into: %{} do
      old = Map.get(before, table, [])
      new = Map.get(current, table, [])

      {table,
       %{
         before?: Map.has_key?(before, table),
         after?: Map.has_key?(current, table),
         added: new -- old,
         removed: old -- new
       }}
    end
  end

  # @cc [owner:ghuntley,label:verification] committed-fixture-inventory-oracle
  # The oracle MUST enumerate every public table independently of cleanup's
  # filters and hash every row field. It MUST preserve row multiplicity and
  # expose no row payloads. Callers MUST own a serial committed-test interval.
  @spec snapshot() :: t()
  def snapshot do
    %{rows: tables} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename",
        [],
        log: false
      )

    Map.new(tables, fn [table] ->
      quoted = String.replace(table, "\"", "\"\"")

      %{rows: rows} =
        Repo.query!(~s|SELECT md5(row_to_json(t)::text) FROM "#{quoted}" t ORDER BY 1|, [],
          log: false
        )

      {table, Enum.map(rows, fn [hash] -> hash end)}
    end)
  end
end
