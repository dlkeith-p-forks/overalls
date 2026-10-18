defmodule GitHubFleetGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification;security] github-fleet-native-commands
  # Fixed commands MUST execute through the authenticated current Firecracker
  # terminal, using installed managed gh/Git and system trust/configuration.
  # Only bounded stage/index/exit receipts may leave this privileged probe;
  # raw terminal bytes and command output MUST remain private.
  @spec run(String.t(), String.t(), String.t(), String.t()) :: :ok
  def run(mode, placement, owner, family)
      when owner in ["1", "2"] and family in ["nixos", "ubuntu", "arch", "almalinux", "windows"] do
    true = OverallsProtocol.uuid?(placement)
    {:ok, terminal} = Terminal.connect(placement)

    try do
      if family != "windows", do: Terminal.ready(terminal, 120_000)

      assertions =
        if family == "windows",
          do: ["if (-not $env:OS.StartsWith('Windows')) { throw 'wrong_os' }" | windows_commands(mode, owner)],
          else: [". /etc/os-release && test \"$ID\" = #{family}" | commands(mode, owner)]

      for {command, index} <- Enum.with_index(assertions, 1) do
        Process.put(:github_fixture_assertion, index)
        marker = "GITHUB_" <> Base.encode16(:crypto.strong_rand_bytes(12))

        :ok =
          Terminal.write(
            terminal,
            wrapped(command, marker, family)
          )

        wait(
          terminal,
          Regex.compile!("\\n#{marker}:([0-9]{1,3})\\n"),
          System.monotonic_time(:millisecond) + 180_000,
          ""
        )
      end

      :ok
    after
      Terminal.close(terminal)
    end
  end

  @spec wrapped(String.t(), String.t(), String.t()) :: String.t()
  defp wrapped(command, marker, "windows") do
    "try { $ErrorActionPreference = 'Stop'; " <>
      "$gh = 'C:\\Program Files\\GitHub CLI\\gh.exe'; " <>
      "$git = 'C:\\Program Files\\Git\\cmd\\git.exe'; " <>
      command <> "; [Console]::WriteLine(\"`n#{marker}:0`n\") } " <>
      "catch { [Console]::WriteLine(\"`n#{marker}:1`n\") }\n"
  end

  defp wrapped(command, marker, _family),
    do: command <> "; result=$?; printf '\\n#{marker}:%s\\n' \"$result\"\n"

  @spec windows_commands(String.t(), String.t()) :: [String.t()]
  defp windows_commands("connected", owner) do
    [
      "$v = & $gh api user --jq .login; if ($LASTEXITCODE -ne 0 -or $v -ne 'owner-#{owner}') { throw 'identity' }",
      "$v = & $gh api repos/owner/private --jq .private; if ($LASTEXITCODE -ne 0 -or $v -ne 'true') { throw 'private' }",
      "$v = & $gh api user/orgs --jq '.[0].login'; if ($LASTEXITCODE -ne 0 -or $v -ne 'fixture-org') { throw 'org' }"
    ]
  end

  defp windows_commands("anonymous", _owner) do
    [
      "$v = & $gh api public --jq .authenticated; if ($LASTEXITCODE -ne 0 -or $v -ne 'false') { throw 'public' }",
      "& $gh api user 2>$null; if ($LASTEXITCODE -eq 0) { throw 'private_admitted' }"
    ]
  end

  defp windows_commands("git", _owner) do
    [
      "& $git clone https://github.com/owner/private.git C:\\github-private; if ($LASTEXITCODE -ne 0) { throw 'clone' }",
      "if ((Get-Content C:\\github-private\\README.md -Raw).Trim() -ne 'Synthetic private GitHub fixture') { throw 'content' }",
      "& $git -C C:\\github-private switch -c fleet-feature; if ($LASTEXITCODE -ne 0) { throw 'branch' }",
      "[IO.File]::WriteAllText('C:\\github-private\\fleet.txt', \"real fleet push`n\"); & $git -C C:\\github-private add fleet.txt; if ($LASTEXITCODE -ne 0) { throw 'stage' }",
      "& $git -C C:\\github-private -c user.name=Fixture -c user.email=fixture@example.test commit -m fleet; if ($LASTEXITCODE -ne 0) { throw 'commit' }",
      "& $git -C C:\\github-private push origin fleet-feature; if ($LASTEXITCODE -ne 0) { throw 'push' }"
    ]
  end

  defp windows_commands("clean", _owner) do
    [
      "$patterns = @(('synthetic' + '-owner-'), ('synthetic-refresh' + '-owner-')); foreach ($e in (Get-ChildItem Env:)) { foreach ($p in $patterns) { if ($e.Value.Contains($p)) { throw 'environment_secret' } } }",
      "$patterns = @(('synthetic' + '-owner-'), ('synthetic-refresh' + '-owner-')); foreach ($f in (Get-ChildItem C:\\Users,C:\\ProgramData\\Overalls -Recurse -File -ErrorAction SilentlyContinue | Where-Object Length -lt 1048576 | Select-Object -First 20000)) { $v = [IO.File]::ReadAllText($f.FullName); foreach ($p in $patterns) { if ($v.Contains($p)) { throw 'file_secret' } } }"
    ]
  end

  @spec commands(String.t(), String.t()) :: [String.t()]
  defp commands("connected", owner) do
    [
      "test \"$(gh api user --jq .login)\" = owner-#{owner}",
      "test \"$(gh api repos/owner/private --jq .private)\" = true",
      "test \"$(gh api user/orgs --jq '.[0].login')\" = fixture-org"
    ]
  end

  defp commands("anonymous", _owner) do
    [
      "test \"$(gh api public --jq .authenticated)\" = false",
      "gh api user >/dev/null 2>&1; test \"$?\" != 0"
    ]
  end

  defp commands("git", _owner) do
    [
      "git clone https://github.com/owner/private.git /root/github-private",
      "test \"$(cat /root/github-private/README.md)\" = 'Synthetic private GitHub fixture'",
      "git -C /root/github-private switch -c fleet-feature",
      "printf 'real fleet push\\n' >/root/github-private/fleet.txt && git -C /root/github-private add fleet.txt",
      "git -C /root/github-private -c user.name=Fixture -c user.email=fixture@example.test commit -m fleet",
      "git -C /root/github-private push origin fleet-feature"
    ]
  end

  defp commands("clean", _owner) do
    [
      "! env | grep -E 'synthetic-owner-|synthetic-refresh-owner-'",
      "! grep -R -I -E 'synthetic-owner-|synthetic-refresh-owner-' /root /home /etc/overalls 2>/dev/null"
    ]
  end

  @spec wait(Terminal.t(), Regex.t(), integer(), binary()) :: :ok
  defp wait(terminal, pattern, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(terminal, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        case Regex.run(pattern, body, capture: :all_but_first) do
          ["0"] ->
            :ok

          [code] ->
            Process.put(:github_fixture_exit, String.to_integer(code))
            raise "GitHub fleet guest assertion failed"

          nil ->
            count = min(byte_size(body), 512)
            wait(terminal, pattern, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(terminal, pattern, until, tail)

      _ ->
        raise "GitHub fleet terminal closed"
    end
  end
end

try do
  [mode, placement, owner, family] = System.argv()
  :ok = GitHubFleetGuest.run(mode, placement, owner, family)
  IO.puts("GitHub fleet guest assertions passed")
rescue
  _ ->
    IO.puts(
      :stderr,
      JSON.encode!(%{
        event: "github_fleet_guest_failed",
        assertion: Process.get(:github_fixture_assertion),
        exit: Process.get(:github_fixture_exit)
      })
    )

    System.halt(1)
end
