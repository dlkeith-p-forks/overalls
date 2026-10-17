Code.require_file("hldd/coverage.ex", __DIR__)
root = Path.expand("..", __DIR__)
data = Overalls.HLDDCoverage.read(root)

case Overalls.HLDDCoverage.validate(root, data) do
  [] -> :ok
  errors -> raise(Enum.join(errors, "\n"))
end

case System.argv() do
  ["--write"] ->
    File.write!(
      Path.join(root, "marshall/priv/hldd/19-coverage.md"),
      Overalls.HLDDCoverage.render(data)
    )

  ["--check"] ->
    if Overalls.HLDDCoverage.check(root) != [], do: raise("scenario chapter is stale")

  _ ->
    raise("usage: elixir scripts/hldd_coverage.exs --write|--check")
end
