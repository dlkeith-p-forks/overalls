# @cc [owner:ghuntley,label:verification] mix-contract-gate-fail-closed
# Each Mix contracts.check invocation MUST run repository syntax/coverage and the
# checker regression tests, propagating a nonzero result instead of skipping it.
root = Path.expand("..", __DIR__)

for args <- [
      [Path.join(__DIR__, "check_contracts.mjs"), "format"],
      ["--test", Path.join(__DIR__, "test/check_contracts_test.mjs")]
    ] do
  case System.cmd("node", args, cd: root, stderr_to_stdout: true) do
    {output, 0} -> IO.write(output)
    {output, _} -> raise "Code contract checks failed:\n#{output}"
  end
end
