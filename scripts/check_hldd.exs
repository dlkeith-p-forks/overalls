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

  ["record", group, disposition, rationale] ->
    Overalls.HLDDGate.record(root, group, disposition, rationale)

  _ ->
    IO.puts(
      :stderr,
      "usage: elixir scripts/check_hldd.exs [record GROUP updated|no-impact RATIONALE]"
    )

    System.halt(1)
end
