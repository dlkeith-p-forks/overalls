defmodule Marshall.InvalidRuntimeBootProbe do
  @moduledoc false
  @entry_points [
    {__MODULE__, :trace_control, 0},
    {Marshall.Application, :start, 2},
    {Marshall.Repo, :start_link, 1},
    {MarshallWeb.Endpoint, :start_link, 1},
    {Bandit, :start_link, 1}
  ]
  @errors %{
    "Invalid inference retention configuration" => "retention_rejected",
    "Invalid Audi ingress integer configuration" => "ingress_port_rejected",
    "Invalid MARSHALL_RELOCATION_READINESS_TIMEOUT_MS (expected 1..600000)" =>
      "readiness_rejected",
    "Invalid MARSHALL_DEFAULT_IMAGE_ID (expected a canonical image digest)" =>
      "default_image_rejected",
    "Invalid MARSHALL_INCEPTION_IMAGE_ID (expected a canonical image digest)" =>
      "inception_image_rejected"
  }

  # @cc [owner:ghuntley,label:security;verification] marshall-early-boot-probe
  # The probe MUST require explicit test opt-in and trace the real Mix startup
  # boundary before runtime evaluation. It MUST export only closed outcomes and
  # booleans, never caught exceptions, trace arguments or environment contents.
  @spec run() :: :ok
  def run do
    unless System.get_env("MIX_ENV") == "test" and
             System.get_env("OVERALLS_BOOT_PROBE") == "test" do
      raise "early boot probe requires explicit test opt-in"
    end

    {:ok, input} = JSON.decode(System.fetch_env!("OVERALLS_PROBE_INPUT"))
    true = is_map(input)

    for {name, value} <- input do
      unless name in [
               "MARSHALL_INFERENCE_DETAIL_DAYS",
               "MARSHALL_INFERENCE_AGGREGATE_DAYS",
               "MARSHALL_INGRESS_HTTPS_PORT",
               "MARSHALL_RELOCATION_READINESS_TIMEOUT_MS",
               "MARSHALL_DEFAULT_IMAGE_ID",
               "MARSHALL_INCEPTION_IMAGE_ID"
             ] and is_binary(value) and byte_size(value) <= 4097 do
        raise "invalid early boot probe input"
      end

      System.put_env(name, value)
    end

    Mix.start()
    Mix.env(:test)
    project = System.fetch_env!("OVERALLS_PROBE_PROJECT")

    Mix.Project.in_project(:marshall, project, fn _ ->
      Mix.Task.run("loadconfig")
      Mix.Task.run("loadpaths", ["--no-deps-check"])
      Enum.each(@entry_points, fn {module, _, _} -> Code.ensure_loaded!(module) end)
      tracer = spawn_link(fn -> trace_loop({false, false}) end)
      Enum.each(@entry_points, fn entry -> 1 = :erlang.trace_pattern(entry, true, [:local]) end)
      :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, tracer}])

      apply(__MODULE__, :trace_control, [])
      outcome = evaluate()
      delivered = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^delivered} -> :ok
      after
        5_000 -> raise "early boot trace delivery timed out"
      end

      reference = make_ref()
      send(tracer, {:finish, self(), reference})

      {attempted, calibrated} =
        receive do
          {^reference, attempted} -> attempted
        after
          5_000 -> raise "early boot trace collection timed out"
        end

      :erlang.trace(:all, false, [:all])

      IO.puts(
        "BOOT_PROBE:" <>
          JSON.encode!(%{
            outcome: outcome,
            startup_attempted: attempted,
            trace_calibrated: calibrated,
            serving_present:
              Enum.any?(
                [Marshall.Supervisor, Marshall.Repo, MarshallWeb.Endpoint],
                &is_pid(Process.whereis(&1))
              ),
            application_started:
              Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :marshall end)
          })
      )
    end)

    :ok
  end

  @spec evaluate() :: String.t()
  defp evaluate do
    case System.get_env("OVERALLS_PROBE_MODE") do
      "reader" ->
        Mix.Task.run("app.config", ["--no-compile", "--no-deps-check"])
        "configured"

      "refusal" ->
        Mix.Task.run("app.start", ["--no-compile", "--no-deps-check"])
        "started"

      _ ->
        "other"
    end
  rescue
    error in RuntimeError ->
      Map.get(@errors, Exception.message(error), "other")

    _ ->
      "other"
  catch
    _, _ -> "other"
  end

  @spec trace_control() :: :ok
  def trace_control, do: :ok

  @spec trace_loop({boolean(), boolean()}) :: :ok
  defp trace_loop({attempted, calibrated} = flags) do
    receive do
      {:trace, _, :call, {module, function, args}} ->
        reviewed = Enum.member?(@entry_points, {module, function, length(args)})
        control = module == __MODULE__ and function == :trace_control
        trace_loop({attempted or (reviewed and not control), calibrated or control})

      {:finish, recipient, reference} ->
        send(recipient, {reference, flags})
        :ok

      _ ->
        trace_loop(flags)
    end
  end
end

Marshall.InvalidRuntimeBootProbe.run()
