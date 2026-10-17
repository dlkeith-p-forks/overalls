Code.require_file("hldd/coverage.ex", __DIR__)
Code.require_file("hldd/views.ex", __DIR__)
Code.require_file("hldd/gate.ex", __DIR__)
root = Path.expand("..", __DIR__)

{mode, file} =
  case System.argv() do
    ["--check"] -> {:check, nil}
    ["--write"] -> {:write, nil}
    ["--check", file] -> {:check, file}
    _ -> raise("usage: elixir scripts/hldd_views.exs --check [JSON_FILE] | --write")
  end

json =
  if file do
    File.read!(file)
  else
    expression =
      "let f = builtins.getFlake " <>
        inspect("git+file://" <> root) <>
        "; in import " <> root <> "/scripts/hldd/topology.nix { flake = f; }"

    case System.cmd("nix", ["eval", "--impure", "--json", "--expr", expression]) do
      {output, 0} -> output
      {_, status} -> raise("NixOS topology evaluation failed (#{status})")
    end
  end

paths = Overalls.HLDDGate.files(root)
if mode == :write, do: Overalls.HLDDViews.write(root, paths, json)

case Overalls.HLDDViews.check(root, paths, json) do
  [] ->
    IO.puts("HLDD Ash and deployment views are current")

  errors ->
    Enum.each(errors, &IO.puts(:stderr, &1))
    System.halt(1)
end
