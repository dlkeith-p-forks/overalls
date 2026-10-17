defmodule DatabaseRecoveryClient do
  @moduledoc false
  alias Ecto.Adapters.SQL

  @root "/var/lib/overalls-fleet"
  @type rendezvous ::
          %{pid: pos_integer()}
          | %{
              client_connection_check_ms: non_neg_integer(),
              tcp_user_timeout_ms: non_neg_integer(),
              healthy_query: boolean()
            }

  # @cc [owner:ghuntley,label:verification] database-recovery-observed-lock-convoy
  # The holder and three waiters MUST use distinct release Repo connections with
  # unchanged production parameters. Rendezvous files MUST remain owner-only;
  # diagnostics may expose backend PIDs, states and timing, never SQL text or
  # credentials. Acquired locks remain held until machine loss or server expiry.
  @spec run() :: no_return()
  def run do
    :ok = :logger.set_primary_config(:level, :none)
    {:ok, _} = Application.ensure_all_started(:ash_postgres)

    {:ok, _} =
      Supervisor.start_link([Marshall.Repo, {Task.Supervisor, name: __MODULE__}],
        strategy: :one_for_one
      )

    fixture = System.fetch_env!("FLEET_FIXTURE_ID")
    %{rows: [[^fixture]]} = query!("SELECT id::text FROM overalls_fleet_fixture")
    # A healthy active query must outlast the production TCP acknowledgement
    # deadline; disconnect detection is not a statement execution timeout.
    %{num_rows: 1} = query!("SELECT pg_sleep(20)")

    %{rows: rows} =
      query!(
        "SELECT name, setting::integer FROM pg_settings WHERE name IN ('idle_in_transaction_session_timeout','tcp_keepalives_idle','tcp_keepalives_interval','tcp_keepalives_count','tcp_user_timeout','client_connection_check_interval')"
      )

    %{
      "idle_in_transaction_session_timeout" => 15_000,
      "tcp_keepalives_idle" => 15,
      "tcp_keepalives_interval" => 5,
      "tcp_keepalives_count" => 3,
      "tcp_user_timeout" => tcp_user_timeout,
      "client_connection_check_interval" => check
    } = Map.new(rows, fn [name, value] -> {name, value} end)

    true = is_integer(check) and check >= 0
    true = is_integer(tcp_user_timeout) and tcp_user_timeout >= 0

    write!("settings", %{
      client_connection_check_ms: check,
      tcp_user_timeout_ms: tcp_user_timeout,
      healthy_query: true
    })

    parent = self()
    active = System.get_env("FLEET_RECOVERY_ACTIVE", "false")
    true = active in ["true", "false"]

    holder =
      Task.Supervisor.async_nolink(__MODULE__, fn -> transaction(0, parent, active == "true") end)

    receive do
      {:locked, 0} -> :ok
    after
      10_000 -> raise "Fixture holder did not acquire its row"
    end

    order = waiter_order(System.get_env("FLEET_RECOVERY_ORDER", "1,2,3"))

    waiters =
      for index <- order,
          do:
            Task.Supervisor.async_nolink(__MODULE__, fn -> transaction(index, parent, false) end)

    Task.await_many([holder | waiters], :infinity)
    exit(:unexpected_transaction_completion)
  end

  # @cc [owner:ghuntley,label:verification] database-recovery-waiter-permutation
  # Generated submission orders MUST include each of the three distinct waiter
  # indices exactly once. Reject all other external values before starting a
  # waiter; submission order MUST NOT be claimed as PostgreSQL queue order.
  @spec waiter_order(String.t()) :: [1..3]
  defp waiter_order(value) do
    case value do
      "1,2,3" -> [1, 2, 3]
      "1,3,2" -> [1, 3, 2]
      "2,1,3" -> [2, 1, 3]
      "2,3,1" -> [2, 3, 1]
      "3,1,2" -> [3, 1, 2]
      "3,2,1" -> [3, 2, 1]
      _ -> raise "Invalid fixture waiter permutation"
    end
  end

  # @cc [owner:ghuntley,label:verification] database-recovery-active-holder
  # Active-holder mode MUST retain the acquired row lock during a real server
  # statement; it MUST NOT change production timeouts or explicitly terminate a
  # backend. The driver must observe active state before injecting machine loss.
  @spec transaction(0..3, pid(), boolean()) :: {:ok, :ok} | {:error, term()}
  defp transaction(index, parent, active) do
    Marshall.Repo.transaction(
      fn ->
        %{rows: [[pid]]} = query!("SELECT pg_backend_pid()")
        true = is_integer(pid) and pid > 0
        write!("backend-#{index}", %{pid: pid})
        %{num_rows: 1} = query!("SELECT id FROM overalls_fleet_fixture FOR UPDATE")
        send(parent, {:locked, index})

        if active, do: query!("SELECT pg_sleep(90)")

        receive do
          :release -> :ok
        after
          90_000 -> raise "Fixture transaction unexpectedly survived"
        end
      end,
      timeout: 95_000
    )
  end

  @spec query!(String.t()) :: Postgrex.Result.t()
  defp query!(statement),
    do: SQL.query!(Marshall.Repo, statement, [], log: false, timeout: 95_000)

  @spec write!(String.t(), rendezvous()) :: :ok
  defp write!(name, value) do
    path = Path.join(@root, name <> ".json")
    File.write!(path <> ".pending", JSON.encode!(value), [:exclusive])
    File.chmod!(path <> ".pending", 0o600)
    File.rename!(path <> ".pending", path)
  end
end

try do
  DatabaseRecoveryClient.run()
rescue
  error ->
    locations =
      for {DatabaseRecoveryClient, function, _arguments, location} <- __STACKTRACE__,
          do: "#{function}:#{Keyword.get(location, :line, 0)}"

    IO.puts(
      "Recovery fixture failed (#{inspect(error.__struct__)}, #{Enum.join(locations, ",")}); private data withheld"
    )

    System.halt(1)
catch
  :exit, _ ->
    IO.puts("Recovery fixture process stopped; private data withheld")
    System.halt(1)
end
