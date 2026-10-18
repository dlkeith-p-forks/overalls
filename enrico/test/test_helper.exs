Code.require_file("../../scripts/test/hegel_fixtures.exs", __DIR__)

# Git operations run through the native enrico-git-owner helper. Packaged
# builds put it on PATH; a source checkout builds it here so the suite never
# depends on a helper left behind by an earlier install.
unless System.find_executable("enrico-git-owner") do
  native = Path.expand("../native/git-owner", __DIR__)

  case System.cmd(
         "cargo",
         ["build", "--quiet", "--locked", "--manifest-path", Path.join(native, "Cargo.toml")],
         stderr_to_stdout: true
       ) do
    {_, 0} ->
      System.put_env(
        "PATH",
        Path.join(native, "target/debug") <> ":" <> System.get_env("PATH", "")
      )

    {output, status} ->
      raise "building enrico-git-owner failed (exit #{status}):\n#{output}"
  end
end

ExUnit.start(exclude: [:skip], formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
