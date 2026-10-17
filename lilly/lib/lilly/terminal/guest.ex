defmodule Lilly.Terminal.Guest do
  require Lilly.Events

  @moduledoc "One guest terminald control connection per VM, authorized by the VM actor."
  use GenServer

  alias Lilly.Terminal.Vsock
  require Lilly.Events

  @timeout 3000

  @enforce_keys [:identity]
  defstruct [:identity, :owner, :socket, sessions: %{}]

  @type identity :: Vsock.identity()

  # @cc [owner:ghuntley,label:recovery] guest-controls-reconnect-lazily
  # The control socket MAY be absent; every operation MUST reconnect on demand
  # and a failed operation MUST NOT close live data sockets owned by channels.
  @spec start_link(pid(), identity()) :: GenServer.on_start()
  def start_link(owner, identity) do
    GenServer.start_link(__MODULE__, %{
      identity: identity,
      owner: owner,
      socket: nil,
      sessions: %{}
    })
  end

  @spec create(
          GenServer.server(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t() | nil
        ) ::
          {:ok, %{guest_session_id: pos_integer(), attach_token: binary()}} | {:error, atom()}
  def create(guest, user, term, cols, rows, request_id \\ nil),
    do: GenServer.call(guest, {:create, user, term, cols, rows, request_id}, @timeout + 2000)

  @spec creation_status(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def creation_status(guest, id),
    do: GenServer.call(guest, {:creation_status, id}, @timeout + 2000)

  @spec cancel_creation(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def cancel_creation(guest, id),
    do: GenServer.call(guest, {:cancel_creation, id}, @timeout + 2000)

  @spec attach(GenServer.server(), pos_integer(), :rw | :ro, non_neg_integer(), keyword()) ::
          {:ok, Vsock.attach()} | {:error, atom()}
  def attach(guest, guest_session_id, mode, cursor, options \\ []),
    do: GenServer.call(guest, {:attach, guest_session_id, mode, cursor, options}, 10_000)

  @spec kill(GenServer.server(), pos_integer()) :: :ok | {:error, atom()}
  def kill(guest, guest_session_id),
    do: GenServer.call(guest, {:kill, guest_session_id}, @timeout + 2000)

  @spec resize(GenServer.server(), pos_integer(), pos_integer(), pos_integer()) ::
          :ok | {:error, atom()}
  def resize(guest, guest_session_id, cols, rows),
    do: GenServer.call(guest, {:resize, guest_session_id, cols, rows}, @timeout)

  @spec list(GenServer.server()) :: {:ok, [Vsock.guest_session()]} | {:error, atom()}
  def list(guest), do: GenServer.call(guest, :list, @timeout)

  @spec users(GenServer.server()) :: {:ok, [String.t()]} | {:error, atom()}
  def users(guest), do: GenServer.call(guest, :users, @timeout + 2000)

  @impl true
  def init(state) do
    Logger.metadata(terminal_stream: true)

    monitor =
      case state.identity[:actor_pid] do
        actor when is_pid(actor) -> Process.monitor(actor)
        _ -> nil
      end

    {:ok, Map.put(state, :actor_monitor, monitor)}
  end

  @impl true
  def handle_call(request, from, %{socket: nil} = state) do
    case Vsock.connect(state.identity) do
      {:ok, socket} -> handle_call(request, from, %{state | socket: socket})
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create, user, term, cols, rows, request_id}, _from, state) do
    with {:ok, socket} <- ensure_socket(state),
         {:ok, created} <- Vsock.create(socket, user, term, cols, rows, request_id: request_id) do
      sessions = Map.put(state.sessions, created.guest_session_id, created.attach_token)
      {:reply, {:ok, created}, %{state | sessions: sessions, socket: socket}}
    else
      {:error, reason} -> {:reply, {:error, reason}, forget_socket(state)}
    end
  end

  def handle_call({:creation_status, id}, _from, state) do
    case Vsock.creation_status(state.socket, id) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      {:error, reason} -> {:reply, {:error, reason}, forget_socket(state)}
    end
  end

  def handle_call({:cancel_creation, id}, _from, state) do
    case Vsock.cancel_creation(state.socket, id) do
      :ok ->
        Lilly.Events.emit("lilly.terminal_creation_cancelled",
          request_id: id,
          placement_id: state.identity.placement_id,
          execution_epoch: state.identity.execution_epoch
        )

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, forget_socket(state)}
    end
  end

  def handle_call({:attach, guest_session_id, mode, cursor, options}, {caller, _tag}, state) do
    case token_for(state, guest_session_id) do
      {:ok, token, state} ->
        case Vsock.attach(
               state.identity,
               guest_session_id,
               token,
               mode,
               cursor,
               Keyword.put(options, :stream_replay, true)
             ) do
          {:ok, attach} ->
            case :gen_tcp.controlling_process(attach.socket, caller) do
              :ok ->
                {:reply, {:ok, attach}, state}

              {:error, _reason} ->
                Vsock.close(attach.socket)
                {:reply, {:error, :attach_failed}, state}
            end

          {:error, :rejected} ->
            {:reply, {:error, :rejected}, state}

          {:error, _reason} ->
            {:reply, {:error, :attach_failed}, forget_socket(state)}
        end

      {:error, _reason} ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:kill, guest_session_id}, _from, state) do
    with {:ok, socket} <- ensure_socket(state),
         :ok <- Vsock.kill(socket, guest_session_id) do
      Lilly.Events.emit("lilly.terminal_guest_retired",
        placement_id: state.identity.placement_id,
        execution_epoch: state.identity.execution_epoch
      )

      {:reply, :ok,
       %{state | sessions: Map.delete(state.sessions, guest_session_id), socket: socket}}
    else
      {:error, reason} -> {:reply, {:error, reason}, forget_socket(state)}
    end
  end

  def handle_call({:resize, guest_session_id, cols, rows}, _from, state) do
    with {:ok, socket} <- ensure_socket(state),
         :ok <- Vsock.resize(socket, guest_session_id, cols, rows) do
      {:reply, :ok, %{state | socket: socket}}
    else
      {:error, reason} -> {:reply, {:error, reason}, forget_socket(state)}
    end
  end

  def handle_call(:users, _from, state) do
    case Vsock.users(state.socket) do
      {:ok, users} -> {:reply, {:ok, users}, state}
      {:error, reason} -> {:reply, {:error, reason}, forget_socket(state)}
    end
  end

  def handle_call(:list, _from, state) do
    with {:ok, socket} <- ensure_socket(state),
         {:ok, sessions} <- Vsock.list(socket) do
      live = for session <- sessions, session.alive, do: session.guest_session_id

      {:reply, {:ok, sessions},
       %{state | socket: socket, sessions: Map.take(state.sessions, live)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, forget_socket(state)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _actor, _reason}, %{actor_monitor: ref} = state)
      when is_reference(ref) do
    send(state.owner, {:guest_actor_gone, self()})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: Vsock.close(state.socket)
    :ok
  end

  @impl true
  def format_status(_opt, state) do
    %{
      data: [
        {"State",
         %{
           identity: %{
             uds_path: state.identity.uds_path,
             placement_id: state.identity.placement_id,
             execution_epoch: state.identity.execution_epoch
           },
           socket: state.socket != nil,
           sessions: map_size(state.sessions)
         }}
      ]
    }
  end

  defp token_for(state, id) do
    case Map.fetch(state.sessions, id) do
      {:ok, token} ->
        {:ok, token, state}

      :error ->
        with {:ok, socket} <- ensure_socket(state),
             {:ok, token} <- Vsock.recover_token(socket, id) do
          {:ok, token, %{state | socket: socket, sessions: Map.put(state.sessions, id, token)}}
        end
    end
  end

  defp ensure_socket(state) do
    case state.socket do
      nil -> Vsock.connect(state.identity)
      socket -> {:ok, socket}
    end
  end

  defp forget_socket(state) do
    if state.socket, do: Vsock.close(state.socket)
    %{state | socket: nil}
  end
end
