Code.require_file("hldd/options.ex", __DIR__)
root = Path.expand("..", __DIR__)

{args, mode} =
  case System.argv() do
    ["--check"] -> {[], :check}
    ["--write"] -> {[], :write}
    ["--check", json] -> {[json], :check}
    _ -> raise("usage: elixir scripts/hldd_options.exs --check [JSON_FILE] | --write")
  end

json =
  case args do
    [file] ->
      File.read!(file)

    [] ->
      expression =
        "let f = builtins.getFlake " <>
          inspect("git+file://" <> root) <>
          "; in import " <> root <> "/scripts/hldd/options.nix { flake = f; }"

      case System.cmd("nix", ["eval", "--impure", "--json", "--expr", expression]) do
        {output, 0} -> output
        {_output, code} -> raise("NixOS option evaluation failed (#{code})")
      end
  end

markdown = Overalls.HLDDOptions.render(json)
path = Path.join(root, "marshall/priv/hldd/18-options.md")

case mode do
  :write ->
    File.write!(path, markdown)

  :check ->
    if File.read!(path) != markdown,
      do:
        raise("HLDD option reference is stale; run hldd_options.exs --write and review the diff")
end
