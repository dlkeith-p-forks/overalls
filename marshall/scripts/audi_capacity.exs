defmodule AudiCapacityTransport do
  @moduledoc false
  @behaviour Plug
  @impl true
  def init(options), do: options

  @impl true
  def call(conn, options) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Marshall.Repo, fn ->
      MarshallWeb.IngressAPI.call(conn, options)
    end)
  end
end

defmodule AudiCapacityRun do
  @moduledoc false
  alias Ecto.Adapters.SQL.Sandbox
  alias Marshall.{Repo, Ingress, IngressCapacityFixtures}
  alias Marshall.Ingress.Token
  alias Marshall.Authorization.SystemActor
  @fixtures Path.expand("../test/fixtures/tls", __DIR__)

  # @cc [owner:ghuntley,label:verification;security] audi-capacity-isolated-database
  # The caller MUST create an exclusive capacity database and drop it after the
  # run. This harness MUST reject other database names and populated hosts before
  # mutation, use only loopback TLS fixtures, and emit no credentials or identities.
  # Failed freshness or updates MUST fail the run, not relax production deadlines.
  @spec run() :: boolean()
  def run do
    name = Repo.config()[:database]

    unless Mix.env() == :test and
             Regex.match?(~r/\Amarshall_test_audi_capacity_run_[0-9a-f]{16}\z/, name),
           do: raise("exclusive capacity test database required")

    mode =
      case System.get_env("AUDI_CAPACITY_TRANSPORT", "https") do
        "https" -> :https
        "action" -> :action
        _ -> raise("invalid capacity transport")
      end

    rounds = String.to_integer(System.get_env("AUDI_CAPACITY_ROUNDS", "3"))
    unless rounds in 1..120, do: raise("capacity rounds must be between 1 and 120")

    Application.put_env(:marshall, :ingress_zone, "apps.example.test")
    Sandbox.mode(Repo, :manual)

    {:ok, {groups, hosts}} =
      Sandbox.unboxed_run(Repo, fn -> Repo.transaction(&prepare/0, timeout: 120_000) end)

    {:ok, listener} =
      Bandit.start_link(
        plug: AudiCapacityTransport,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        certfile: Path.join(@fixtures, "localhost.pem"),
        keyfile: Path.join(@fixtures, "localhost.key")
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)

    groups =
      Enum.map(groups, fn {host, token, requests} ->
        {:ok, client} =
          Audi.Control.Client.new("https://127.0.0.1:#{port}", token, :gateway,
            host_id: host,
            cacertfile: Path.join(@fixtures, "ca.pem")
          )

        {client, requests}
      end)

    {:ok, db} =
      Postgrex.start_link(
        Keyword.take(Repo.config(), [:hostname, :username, :password, :database, :port])
      )

    heartbeat = Task.async(fn -> beat(db, hosts) end)

    {:ok, sampler_db} =
      Postgrex.start_link(
        Keyword.take(Repo.config(), [:hostname, :username, :password, :database, :port])
      )

    emit(%{
      measurement: "audi_capacity_setup",
      transport: mode,
      gateways: length(groups),
      routes: 10_000,
      schedulers: System.schedulers_online(),
      pool_size: Repo.config()[:pool_size]
    })

    try do
      Enum.map(1..rounds, fn round -> measure(groups, hosts, mode, round, sampler_db) end)
      |> Enum.all?()
    after
      send(heartbeat.pid, :stop)
      Task.await(heartbeat, 5000)
      GenServer.stop(db)
      GenServer.stop(sampler_db)
      GenServer.stop(listener)
    end
  end

  defp prepare do
    %{rows: [[0]]} = sql("SELECT count(*) FROM compute_hosts", [])
    c = IngressCapacityFixtures.fixture()
    IngressCapacityFixtures.populate(c)
    %{rows: identities} = sql("SELECT service, host FROM audi_capacity_hosts", [])

    tokens =
      Map.new(identities, fn [service, _] ->
        {token, digest} = Token.issue()
        sql("UPDATE ingress_services SET token_hash=$1 WHERE id=$2", [digest, service])
        {service, token}
      end)

    %{rows: rows} = sql("SELECT vm::text, placement::text, service FROM audi_capacity_vms", [])
    grouped = Enum.group_by(rows, &List.last/1)

    groups =
      Enum.map(identities, fn [service, host] ->
        requests =
          Enum.map(grouped[service], fn [vm, placement, _] ->
            Map.merge(c.request, %{
              service_token: tokens[service],
              vm_id: vm,
              placement_id: placement
            })
          end)

        {Ecto.UUID.load!(host), tokens[service], requests}
      end)

    sql("SET CONSTRAINTS ALL IMMEDIATE", [])
    {groups, Enum.map(identities, &List.last/1)}
  end

  # @cc [owner:ghuntley,label:verification] audi-capacity-sampled-freshness
  # After the bootstrap round, any sampled expired or missing route MUST fail
  # the round even if all routes recover by its end. Diagnostics MUST report
  # sample count and maximum observed gap; finite samples MUST NOT be described
  # as continuous availability or physical fleet evidence.
  defp measure(groups, hosts, mode, round, sampler_db) do
    sampler = Task.async(fn -> sample_freshness(sampler_db, hosts) end)

    {elapsed, results} =
      :timer.tc(fn ->
        Task.async_stream(
          groups,
          fn {client, requests} ->
            Enum.count(requests, fn request -> match?({:ok, _}, report(mode, client, request)) end)
          end,
          max_concurrency: 100,
          timeout: 120_000,
          ordered: false
        )
        |> Enum.to_list()
      end)

    successful =
      Enum.reduce(results, 0, fn
        {:ok, count}, acc -> acc + count
        _, acc -> acc
      end)

    fresh =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[count]]} =
          sql(
            "SELECT count(*) FROM ingress_routes WHERE host_id=ANY($1::uuid[]) AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')",
            [hosts]
          )

        count
      end)

    send(sampler.pid, :stop)
    samples = Task.await(sampler, 5000)
    sampled_fresh = round == 1 or samples.minimum_fresh_routes == 10_000
    passed = successful == 10_000 and fresh == 10_000 and elapsed < 5_000_000 and sampled_fresh

    emit(%{
      measurement: "audi_capacity_round",
      transport: mode,
      round: round,
      microseconds: elapsed,
      successful: successful,
      fresh_routes: fresh,
      freshness_samples: samples.count,
      minimum_sampled_fresh_routes: samples.minimum_fresh_routes,
      maximum_sample_gap_ms: samples.maximum_gap_ms,
      bootstrap: round == 1,
      passed: passed
    })

    passed
  end

  defp sample_freshness(db, hosts) do
    sample_freshness(db, hosts, %{
      count: 0,
      minimum_fresh_routes: 10_000,
      previous_at: System.monotonic_time(:millisecond),
      maximum_gap_ms: 0
    })
  end

  defp sample_freshness(db, hosts, samples) do
    %{rows: [[fresh]]} =
      Postgrex.query!(
        db,
        "SELECT count(*) FROM ingress_routes WHERE host_id=ANY($1::uuid[]) AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')",
        [hosts],
        timeout: 2000
      )

    instant = System.monotonic_time(:millisecond)

    samples = %{
      count: samples.count + 1,
      minimum_fresh_routes: min(samples.minimum_fresh_routes, fresh),
      previous_at: instant,
      maximum_gap_ms: max(samples.maximum_gap_ms, instant - samples.previous_at)
    }

    receive do
      :stop -> samples
    after
      100 -> sample_freshness(db, hosts, samples)
    end
  end

  defp report(:action, _, request),
    do:
      Sandbox.unboxed_run(Repo, fn ->
        Ingress.report_ready_route(request, actor: SystemActor.compute())
      end)

  defp report(:https, client, request) do
    request =
      request
      |> Map.delete(:service_token)
      |> Map.update!(:certificate_expires_at, &DateTime.to_iso8601/1)

    Audi.Control.Client.report_ready_route(client, request)
  end

  defp beat(db, hosts) do
    Postgrex.query!(
      db,
      "UPDATE compute_hosts SET reported_at=clock_timestamp() AT TIME ZONE 'UTC' WHERE id=ANY($1::uuid[])",
      [hosts],
      timeout: 2000
    )

    receive do
      :stop -> :ok
    after
      1000 -> beat(db, hosts)
    end
  end

  defp sql(query, params), do: Ecto.Adapters.SQL.query!(Repo, query, params, log: false)
  defp emit(value), do: IO.puts(JSON.encode!(value))
end

if AudiCapacityRun.run(), do: System.halt(0), else: System.halt(1)
