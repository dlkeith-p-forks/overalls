defmodule Lilly.Host.TemplateSteward do
  @moduledoc """
  One template build per pool and image (ADR-0176 decision 3).

  Callers that find no ready template ask the steward instead of racing for
  the image's exclusive lease: the first request starts a single build, and
  every later request for the same pool and image subscribes to its result.
  The build runs in its own process under the exclusive lease exactly as
  before, so its native custody is unchanged; a caller that stops waiting
  never cancels it.
  """
  use GenServer
  alias Lilly.Host.{Image, ImageTemplate, Pool}

  @type key :: {Path.t(), String.t()}
  @type build :: %{pid: pid(), monitor: reference(), waiters: [GenServer.from()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(options, :name, __MODULE__))

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}

  # @cc [owner:ghuntley,label:concurrency;recovery] template-build-single-flight
  # ensure/3 MUST run at most one build at a time per pool path and image id
  # in this BEAM. Every concurrent caller for that pool and image MUST receive
  # the result of that single build, or storage_busy when its own wait expires
  # first; a caller that stops waiting MUST NOT cancel or repeat the build. A
  # build that exits abnormally answers template_unconfirmed. A BEAM without
  # a steward builds inline.
  @spec ensure(
          Pool.t(),
          Image.t(),
          pos_integer(),
          (Pool.t(), Image.t() -> ImageTemplate.result())
        ) :: ImageTemplate.result()
  def ensure(pool, image, wait_ms, build \\ &ImageTemplate.build_now/2)
      when is_integer(wait_ms) and wait_ms > 0 and is_function(build, 2) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:ensure, pool, image, build}, wait_ms)
      catch
        :exit, _ -> {:error, :storage_busy}
      end
    else
      build.(pool, image)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{builds: %{}}}

  @impl true
  def handle_call({:ensure, pool, image, build}, from, state) do
    key = {pool.path, image.id}

    case state.builds[key] do
      %{waiters: waiters} = build ->
        {:noreply, put_in(state.builds[key], %{build | waiters: [from | waiters]})}

      nil ->
        steward = self()

        {pid, monitor} =
          spawn_monitor(fn ->
            send(steward, {:built, key, self(), build.(pool, image)})
          end)

        {:noreply, put_in(state.builds[key], %{pid: pid, monitor: monitor, waiters: [from]})}
    end
  end

  @impl true
  def handle_info({:built, key, pid, result}, state) do
    case state.builds[key] do
      %{pid: ^pid, monitor: monitor, waiters: waiters} ->
        Process.demonitor(monitor, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:noreply, %{state | builds: Map.delete(state.builds, key)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.builds, fn {_key, build} -> build.monitor == monitor end) do
      {key, %{waiters: waiters}} ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, :template_unconfirmed}))
        {:noreply, %{state | builds: Map.delete(state.builds, key)}}

      nil ->
        {:noreply, state}
    end
  end
end
