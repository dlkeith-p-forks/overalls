defmodule Marshall.OperatorBootProbe do
  @moduledoc false

  @spec run() :: :ok
  def run do
    Application.put_env(:marshall, :operator_mode, true)
    {:ok, _} = Application.ensure_all_started(:marshall)

    children =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(Marshall.Supervisor),
          do: id

    oban = Oban.config()

    IO.puts(
      "OPERATOR_PROBE:" <>
        JSON.encode!(%{
          "children" => Enum.sort(Enum.map(children, &to_string/1)),
          "endpoint_present" => is_pid(Process.whereis(MarshallWeb.Endpoint)),
          "endpoint_server_disabled" => MarshallWeb.Endpoint.config(:server) == false,
          "queues_empty" => oban.queues == [],
          "plugins_empty" => oban.plugins == [],
          "stager_disabled" => oban.stager == false,
          "isolated_peer" => match?({Oban.Peers.Isolated, _}, oban.peer)
        })
    )

    :ok = Application.stop(:marshall)
    :ok
  end
end

Mix.start()
Mix.env(:test)
project = Path.expand("..", __DIR__)

Mix.Project.in_project(:marshall, project, fn _ ->
  Mix.Task.run("loadconfig")
  Mix.Task.run("loadpaths", ["--no-deps-check"])
  Code.ensure_loaded!(Marshall.Application)
  Marshall.OperatorBootProbe.run()
end)
