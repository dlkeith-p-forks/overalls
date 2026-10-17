defmodule RepositoryLaunchGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  @type api_provider :: :none | :codeberg | :bitbucket
  @type assertion_stage ::
          :provider_api_tls | :provider_api_schema | :provider_fork_git | :checkout_assertion

  # @cc [owner:ghuntley,label:verification;security] repository-launch-guest-checkout
  # Checkout probes MUST run fixed commands inside the actual current Firecracker
  # boot through the authenticated terminal. The guest's own clone status MUST
  # reach done, HEAD MUST equal the expected fixture commit and the checkout MUST
  # be shallow. After a restart the retained checkout, its local probe file and
  # the done marker MUST survive, proving the guest never re-clones. Terminal
  # bytes never leave this probe. Executed nonzero results MUST fail immediately;
  # diagnostics MUST contain only fixed stages, assertion indices, integer exit
  # codes and the closed guest clone-status vocabulary.
  @spec run(String.t(), String.t(), String.t(), String.t(), api_provider()) :: :ok
  def run(mode, placement, repo, sha, api_provider)
      when mode in ["clone", "retained"] and api_provider in [:none, :codeberg, :bitbucket] do
    true = OverallsProtocol.uuid?(placement)
    true = Regex.match?(~r/\A[A-Za-z0-9._-]{1,100}\z/, repo)
    true = Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)
    {:ok, terminal} = Terminal.connect(placement)

    try do
      Process.put(:fixture_stage, :shell_ready)
      :ok = Terminal.ready(terminal, 120_000)
      IO.puts("Repository launch guest shell ready")

      for {{stage, command}, index} <- Enum.with_index(api_commands(api_provider, sha), 1) do
        execute(terminal, stage, index, command)
      end

      dir = "/workspace/" <> repo
      git = "git -c safe.directory='*' -C " <> dir

      done =
        "for i in $(seq 1 300); do s=$(cat /run/overalls-workspace/status 2>/dev/null); " <>
          "[ \"$s\" = done ] && break; [ \"$s\" = failed ] && break; sleep 1; done; " <>
          "test \"$(cat /run/overalls-workspace/status)\" = done"

      head = "test \"$(#{git} rev-parse HEAD)\" = #{sha}"

      commands =
        case mode do
          "clone" ->
            [
              done,
              head,
              "test \"$(#{git} rev-parse --is-shallow-repository)\" = true",
              "test -f /var/lib/overalls-workspace/done",
              "touch #{dir}/.launch-probe"
            ]

          "retained" ->
            [done, head, "test -f #{dir}/.launch-probe", "test ! -e /workspace/.#{repo}.partial"]
        end

      for {command, index} <- Enum.with_index(commands, 1) do
        execute(terminal, :checkout_assertion, index, command)
      end

      :ok
    after
      Terminal.close(terminal)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] repository-api-fixture-probes
  # API fixture probes MUST use the current guest's installed trust bundle and
  # fixed provider URLs, validate the response shape and exact fork head, and
  # check fork Git transport without printing response or terminal bytes. These
  # probes MUST NOT substitute for the guest-owned clone's done/HEAD assertions.
  @spec api_commands(api_provider(), String.t()) :: [{assertion_stage(), String.t()}]
  defp api_commands(:none, _sha), do: []

  defp api_commands(provider, sha) do
    {url, fork, schema} =
      case provider do
        :codeberg ->
          {"https://codeberg.org/api/v1/repos/overalls/fixture/pulls/7",
           "https://codeberg.org/forks/fixture.git",
           "type == \"object\" and (.head | type == \"object\") and " <>
             "(.head.repo | type == \"object\") and " <>
             ".head.repo.clone_url == $url and .head.sha == $sha"}

        :bitbucket ->
          {"https://api.bitbucket.org/2.0/repositories/overalls/fixture/pullrequests/7",
           "https://bitbucket.org/forks/fixture.git",
           "type == \"object\" and (.source | type == \"object\") and " <>
             "(.source.commit | type == \"object\") and .source.commit.hash == $sha and " <>
             "(.source.repository.links.clone | type == \"array\" and " <>
             "any(.[]; type == \"object\" and .name == \"https\" and .href == $url))"}
      end

    [
      {:provider_api_tls,
       "fixture_api=$(mktemp /tmp/overalls-repository-api.XXXXXX) && " <>
         "curl --silent --fail --noproxy '*' --connect-timeout 10 --max-time 30 " <>
         "--cacert /etc/ssl/certs/ca-certificates.crt --output \"$fixture_api\" #{url}"},
      {:provider_api_schema,
       "jq -e --arg url #{fork} --arg sha #{sha} '#{schema}' \"$fixture_api\" >/dev/null; " <>
         "schema_result=$?; rm -f \"$fixture_api\"; test \"$schema_result\" = 0"},
      {:provider_fork_git,
       "fork_refs=$(timeout 30 git ls-remote --exit-code --heads -- #{fork} refs/heads/main " <>
         "2>/dev/null); fork_result=$?; test \"$fork_result\" = 0 && " <>
         "test \"$(printf '%s\\n' \"$fork_refs\" | cut -f1)\" = #{sha}"}
    ]
  end

  @spec execute(Terminal.t(), assertion_stage(), pos_integer(), String.t()) :: :ok
  defp execute(terminal, stage, index, command) do
    Process.put(:fixture_stage, stage)
    Process.put(:fixture_assertion, index)
    marker = "LAUNCH_" <> Base.encode16(:crypto.strong_rand_bytes(12))

    :ok =
      Terminal.write(
        terminal,
        command <>
          "; result=$?; s=$(cat /run/overalls-workspace/status 2>/dev/null); " <>
          "case \"$s\" in waiting|cloning|done|failed) ;; '') s=missing ;; *) s=invalid ;; esac; " <>
          "printf '\\n#{marker}:%s:%s\\n' \"$result\" \"$s\"\n"
      )

    pattern =
      Regex.compile!("\\n#{marker}:([0-9]{1,3}):(waiting|cloning|done|failed|missing|invalid)\\n")

    wait(terminal, pattern, deadline(360_000), "")
  end

  @spec deadline(pos_integer()) :: integer()
  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  @spec wait(Terminal.t(), Regex.t(), integer(), binary()) :: :ok
  defp wait(terminal, pattern, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(terminal, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        case Regex.run(pattern, body, capture: :all_but_first) do
          ["0", status] ->
            Process.put(:fixture_clone_status, status)
            :ok

          [result, status] ->
            Process.put(:fixture_exit, String.to_integer(result))
            Process.put(:fixture_clone_status, status)
            raise "Launch fixture assertion failed"

          nil ->
            count = min(byte_size(body), 512)
            wait(terminal, pattern, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(terminal, pattern, until, tail)

      _ ->
        raise "Launch fixture terminal closed"
    end
  end
end

try do
  [mode, placement, repo, sha, api] = System.argv()

  api_provider =
    case api do
      "none" -> :none
      "codeberg" -> :codeberg
      "bitbucket" -> :bitbucket
    end

  :ok = RepositoryLaunchGuest.run(mode, placement, repo, sha, api_provider)
  IO.puts("Repository launch guest assertions passed")
rescue
  _ ->
    observation = %{
      stage: Process.get(:fixture_stage, :arguments),
      assertion: Process.get(:fixture_assertion),
      exit: Process.get(:fixture_exit),
      clone_status: Process.get(:fixture_clone_status)
    }

    IO.puts(:stderr, "Repository launch guest assertions failed; terminal bytes withheld")
    IO.puts(:stderr, "REPOSITORY_GUEST_FAILED " <> JSON.encode!(observation))
    System.halt(1)
end
