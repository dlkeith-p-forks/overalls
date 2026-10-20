Code.require_file("hldd/coverage.ex", __DIR__)
Code.require_file("hldd/views.ex", __DIR__)
Code.require_file("hldd/gate.ex", __DIR__)
root = Path.expand("..", __DIR__)

case System.argv() do
  [] ->
    case Overalls.HLDDGate.check(root) do
      [] ->
        IO.puts("HLDD review receipts and references are current")

      errors ->
        Enum.each(errors, &IO.puts(:stderr, &1))
        System.halt(1)
    end

  ["status"] ->
    for row <- Overalls.HLDDGate.status(root), row.status != "current" do
      IO.puts(
        "#{row.status} #{row.path} [#{Enum.join(row.groups, ", ")}] -> #{Enum.join(row.chapters, ", ")}"
      )
    end

  ["migrate", legacy_root] ->
    Code.require_file("hldd/migration.ex", __DIR__)
    Overalls.HLDDMigration.run(root, Path.expand(legacy_root))

  ["record", group, disposition, rationale | options] ->
    {parsed, [], []} = OptionParser.parse(options, strict: [path: :keep])

    Overalls.HLDDGate.record(
      root,
      group,
      disposition,
      rationale,
      Keyword.get_values(parsed, :path)
    )

  _ ->
    IO.puts(
      :stderr,
      "usage: elixir scripts/check_hldd.exs [status | migrate LEGACY_ROOT | record GROUP updated|no-impact RATIONALE [--path PATH]...]"
    )

    System.halt(1)
end
