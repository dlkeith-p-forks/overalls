defmodule Overalls.Diagnostics.SchemaGenerationTest do
  use ExUnit.Case, async: false

  @schema_keys ~w(services uuid_attributes enum_attributes numeric_attributes enum_values)

  # @cc [owner:ghuntley,label:verification] trace-schema-fresh-vm-repeatability
  # Fresh VMs with opposing schema-key atom-loading orders MUST accept the actual
  # production vocabulary and MUST leave its generated artifact byte-identical.
  test "production schema checks pass across fresh VM atom-loading orders" do
    artifact = Path.expand("../priv/trace-schema.json", __DIR__)
    before = File.read!(artifact)

    for keys <- [@schema_keys, Enum.reverse(@schema_keys)] do
      assert {"", 0} == check_in_fresh_vm(keys)
    end

    assert File.read!(artifact) == before
  end

  @spec check_in_fresh_vm([String.t()]) :: {String.t(), non_neg_integer()}
  defp check_in_fresh_vm(keys) do
    executable = System.find_executable("elixir") || raise "pinned Elixir executable missing"
    jason = Jason |> Code.ensure_loaded!() |> :code.which() |> List.to_string() |> Path.dirname()

    script =
      "Enum.each(#{inspect(keys)}, &String.to_atom/1); Code.eval_file(\"generate_schema.exs\")"

    System.cmd(executable, ["-pa", jason, "-e", script, "--", "--check"],
      cd: Path.expand("..", __DIR__),
      stderr_to_stdout: true
    )
  end
end
