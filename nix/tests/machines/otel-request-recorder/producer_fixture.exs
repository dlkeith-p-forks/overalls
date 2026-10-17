defmodule RequestProducerFixture.Server do
  @moduledoc "Disposable BEAM control fixture using the production producer client."
  use GenServer
  alias Overalls.RequestAccounting.Producer

  @type state :: %{
          listener: :gen_tcp.socket(),
          next_id: pos_integer(),
          workers: %{pos_integer() => pid()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    Process.flag(:trap_exit, true)
    path = System.fetch_env!("FIXTURE_CONTROL")
    _removed = File.rm(path)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:packet, 4},
        {:packet_size, 512},
        {:ip, {:local, String.to_charlist(path)}}
      ])

    send(self(), :accept)
    {:ok, %{listener: listener, next_id: 1, workers: %{}}}
  end

  @impl true
  @spec handle_info(:accept, state()) :: {:noreply, state()}
  def handle_info(:accept, state) do
    state =
      case :gen_tcp.accept(state.listener, 100) do
        {:ok, socket} ->
          {reply, next} =
            case :gen_tcp.recv(socket, 0, 1_000) do
              {:ok, bytes} -> dispatch(JSON.decode!(bytes), state)
              _ -> {%{status: :refused, reason: :schema}, state}
            end

          :ok = :gen_tcp.send(socket, JSON.encode!(reply))
          :gen_tcp.close(socket)
          next

        {:error, :timeout} ->
          state
      end

    send(self(), :accept)
    {:noreply, state}
  end

  # @cc [owner:ghuntley,label:verification] producer-fixture-observed-worker-death
  # A fixture kill reply MUST follow the exact worker's monitored :killed death.
  # Missing proof MUST fail visibly, never report the requested fault as complete.
  @spec dispatch(map(), state()) :: {map(), state()}
  defp dispatch(%{"version" => 1, "command" => %{"op" => "admit"}}, state) do
    parent = self()
    worker = spawn(fn -> worker(parent) end)
    ticket = Producer.admit(RequestProducerFixture.Client, worker)
    send(worker, {:ticket, ticket})

    receive do
      {:ready, ^worker, true} ->
        {%{status: :admitted, id: state.next_id},
         %{
           state
           | next_id: state.next_id + 1,
             workers: Map.put(state.workers, state.next_id, worker)
         }}

      {:ready, ^worker, false} ->
        {%{status: :refused, reason: :storage}, state}
    after
      8_000 ->
        Process.exit(worker, :kill)
        {%{status: :refused, reason: :storage}, state}
    end
  end

  defp dispatch(
         %{"version" => 1, "command" => %{"op" => "finish", "id" => id, "outcome" => outcome}},
         state
       ) do
    case Map.pop(state.workers, id) do
      {nil, _workers} ->
        {%{status: :refused, reason: :accounting}, state}

      {worker, workers} ->
        if outcome == "exclude" do
          # Fixture-only command: force a worker death inside the surviving BEAM.
          monitor = Process.monitor(worker)
          Process.exit(worker, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^worker, :killed} -> :ok
          after
            8_000 -> raise "Fixture worker death was not observed"
          end
        else
          send(worker, {:finish, if(outcome == "success", do: :success, else: :failure), self()})

          receive do
            {:finished, ^worker} -> :ok
          after
            8_000 -> Process.exit(worker, :kill)
          end
        end

        {%{status: :ok}, %{state | workers: workers}}
    end
  end

  defp dispatch(%{"version" => 1, "command" => %{"op" => "hello"}}, state),
    do: {%{status: :ok}, state}

  defp dispatch(_command, state), do: {%{status: :refused, reason: :schema}, state}

  @spec worker(pid()) :: :ok
  defp worker(parent) do
    ticket =
      receive do
        {:ticket, ticket} -> ticket
      end

    send(parent, {:ready, self(), ticket != :unrecorded})

    if ticket != :unrecorded do
      receive do
        {:finish, outcome, reply_to} ->
          :ok = Producer.complete(RequestProducerFixture.Client, ticket, outcome, 100)
          send(reply_to, {:finished, self()})
      end
    end

    :ok
  end
end

defmodule RequestProducerFixture.Application do
  @moduledoc "Native fixture application; orderly OTP shutdown stops source before client."
  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = client_children() ++ [{RequestProducerFixture.Server, []}]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  @spec client_children() :: [{module(), Overalls.RequestAccounting.Config.t()}]
  defp client_children do
    case {System.get_env("FIXTURE_RECORDER"), System.get_env("FIXTURE_MARKER")} do
      {nil, nil} ->
        Overalls.RequestAccounting.Producer.children(RequestProducerFixture.Client)

      {socket, directory} when is_binary(socket) and is_binary(directory) ->
        [
          {Overalls.RequestAccounting.Producer,
           Overalls.RequestAccounting.Config.new!(
             name: RequestProducerFixture.Client, socket: socket, directory: directory)}
        ]
    end
  end
end

# @cc [owner:ghuntley,label:verification] producer-native-fixture-scope
# This fixture MUST run the production Elixir client inside an OTP application
# and the exact configured unit. It MUST NOT enter a production release closure.
:ok =
  :application.load(
    {:application, :request_producer_fixture,
     [
       description: ~c"Native SLO producer fixture",
       vsn: ~c"1",
       applications: [:kernel, :stdlib, :elixir],
       mod: {RequestProducerFixture.Application, []}
     ]}
  )

{:ok, _applications} = Application.ensure_all_started(:request_producer_fixture)
