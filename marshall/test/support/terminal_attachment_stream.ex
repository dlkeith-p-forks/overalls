defmodule Marshall.TerminalAttachmentStream do
  @moduledoc false
  use GenServer

  @type attach :: %{
          type: :attach,
          cols: non_neg_integer(),
          rows: non_neg_integer(),
          vm_id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          guest_session_id: pos_integer(),
          mode: :rw | :ro,
          cursor: non_neg_integer()
        }
  @type resize :: %{
          type: :resize,
          cols: pos_integer(),
          rows: pos_integer(),
          vm_id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          guest_session_id: pos_integer()
        }
  @type effect ::
          {:attach, pid(), attach()}
          | {:input, pos_integer(), binary()}
          | {:resize, resize()}
          | {:gone, pos_integer()}
  @type state :: %{
          next: pos_integer(),
          effects: [effect()],
          sessions: [Marshall.TerminalFixtures.fake_session()]
        }

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(host_id), do: GenServer.start_link(__MODULE__, host_id)

  @spec effects(pid()) :: [effect()]
  def effects(pid), do: GenServer.call(pid, :effects)

  @impl true
  def init(host_id) do
    :ok = Marshall.Terminal.Relay.register(Marshall.Terminal.Relay, host_id, self())
    {:ok, %{next: 1, effects: [], sessions: []}}
  end

  @impl true
  def handle_call(:effects, _from, state), do: {:reply, Enum.reverse(state.effects), state}

  # @cc [owner:ghuntley,label:verification] attachment-synthetic-stream-boundary
  # Record every attach/input/resize/detach dispatched by the real Viewer.
  # Replies are synthetic guest receipts only and MUST NOT be described as
  # actual terminal execution, transport fencing, replay or native isolation.
  @impl true
  def handle_info({:relay_control, request}, state) do
    {reply, sessions} =
      case request.message do
        %{type: :creation_query, request_id: id} ->
          {%{type: :creation_status, request_id: id, state: :unknown, guest_session_id: nil},
           state.sessions}

        %{type: :create, request_id: id} ->
          {%{type: :created, request_id: id, ok: true, guest_session_id: state.next},
           [
             %{
               guest_session_id: state.next,
               user: "root",
               cols: 80,
               rows: 24,
               viewers: 0,
               alive: true,
               created_ms: 1,
               last_ms: 1
             }
             | state.sessions
           ]}

        %{type: :listing, vm_id: vm_id} ->
          {%{type: :listed, vm_id: vm_id, sessions: state.sessions}, state.sessions}
      end

    Marshall.Terminal.Relay.reply(request, {:ok, reply})
    {:noreply, %{state | next: state.next + 1, sessions: sessions}}
  end

  def handle_info({:viewer_attach, request}, state) do
    send(
      request.caller,
      {:terminal_attached,
       %{
         channel: state.next,
         replay_bytes: 0,
         guest_session_id: request.message.guest_session_id,
         from: request.message.cursor
       }}
    )

    {:noreply,
     %{
       state
       | next: state.next + 1,
         effects: [{:attach, request.caller, request.message} | state.effects]
     }}
  end

  def handle_info({:viewer_input, channel, bytes}, state),
    do: {:noreply, %{state | effects: [{:input, channel, bytes} | state.effects]}}

  def handle_info({:viewer_resize, message}, state),
    do: {:noreply, %{state | effects: [{:resize, message} | state.effects]}}

  def handle_info({:viewer_gone, channel}, state),
    do: {:noreply, %{state | effects: [{:gone, channel} | state.effects]}}

  # Output credit receipts are flow control, not an observable session effect.
  def handle_info({:viewer_output_ack, _channel, _frames, _bytes}, state), do: {:noreply, state}
end
