defmodule Audi.SSH.Channel do
  @moduledoc "Backpressured SSH byte relay with an independently enforced authority deadline."
  @behaviour :ssh_server_channel
  alias Audi.Authority.StreamGuard
  alias Audi.SSH.{Proof, Request, State}
  alias OverallsProtocol.SSHOnboarding
  require Audi.Events

  @impl true
  def init([config | _]) do
    :logger.update_process_metadata(%{audi_private: true, audi_component: :ssh})
    Process.flag(:trap_exit, true)
    {:ok, timeout} = :timer.kill_after(8000, self())

    {:ok,
     %{
       config: config,
       phase: :awaiting,
       pty: false,
       connection: nil,
       channel: nil,
       socket: nil,
       guard: nil,
       grant: nil,
       deadline: nil,
       worker: nil,
       renewal: nil,
       setup: timeout,
       eof: false
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel, connection}, state),
    do: {:ok, %{state | channel: channel, connection: connection}}

  def handle_msg({:tcp, socket, bytes}, %{socket: socket} = state) do
    if active?(state) and byte_size(bytes) <= 65_536 and
         :ssh_connection.send(state.connection, state.channel, 0, bytes, 1000) == :ok do
      :ok = :inet.setopts(socket, active: :once)
      {:ok, state}
    else
      finish(state, 1)
    end
  end

  def handle_msg({:tcp_closed, socket}, %{socket: socket} = state), do: finish(state, 0)
  def handle_msg({:tcp_error, socket, _}, %{socket: socket} = state), do: finish(state, 1)

  def handle_msg(:renew, %{worker: nil, grant: grant} = state) when not is_nil(grant) do
    owner = self()
    reference = make_ref()
    started = now()
    backend = state.config.backend

    worker =
      spawn_link(fn ->
        :logger.update_process_metadata(%{audi_private: true, audi_component: :ssh})
        result = invoke(backend, :renew, [grant.ticket, grant.binding])
        send(owner, {:renewed, reference, result})
      end)

    {:ok, %{state | worker: {worker, reference, started}, renewal: nil}}
  end

  def handle_msg({:renewed, reference, result}, %{worker: {_, reference, started}} = state) do
    state = %{state | worker: nil}

    now = System.monotonic_time(:millisecond)

    with {:ok, %{binding: _, ttl: ttl} = renewed} <- result,
         :ok <- StreamGuard.renew(state.guard, Request.authority_binding(renewed), started, ttl) do
      {:ok, schedule(%{state | deadline: started + ttl}, ttl)}
    else
      # Inconclusive renewal keeps the current lease and retries; the guard
      # still ends the stream at its deadline (ADR-0140).
      error ->
        if Audi.Authority.Renewal.inconclusive?(error) and is_integer(state.deadline) and
             state.deadline > now do
          delay = Audi.Authority.Renewal.retry_after(state.deadline, now)
          {:ok, %{state | renewal: Process.send_after(self(), :renew, delay)}}
        else
          finish(state, 1)
        end
    end
  end

  # An authority hint for this session's VM or user renews (or ends) it now;
  # a renewal already in flight answers the same question.
  def handle_msg({:control_hint, _kind, _id}, %{worker: nil, grant: grant} = state)
      when not is_nil(grant) do
    if state.renewal, do: Process.cancel_timer(state.renewal)
    handle_msg(:renew, %{state | renewal: nil})
  end

  def handle_msg({:EXIT, worker, _}, %{worker: {worker, _, _}} = state), do: finish(state, 1)
  def handle_msg({:EXIT, guard, _}, %{guard: guard} = state), do: finish(state, 1)
  def handle_msg(_, state), do: {:ok, state}

  # @cc [owner:ghuntley,label:security] audi-ssh-stream-admission
  # An exec request MUST select only a stable VM label or a fixed Inception
  # service selector. A proved key, a current host-bound SSH grant and a
  # caller-owned connector socket are required before stream admission or data forwarding.
  # Rejected requests may acknowledge diagnostic handling on stderr only.
  # Nested renewal MUST preserve the published host key as well as placement.
  # Untrusted command text MUST never reach a shell.
  @impl true
  def handle_ssh_msg({:ssh_cm, connection, {:exec, channel, reply, command}}, state) do
    {phase, effect} = State.step(state.phase, :exec)
    state = %{state | phase: phase, connection: connection, channel: channel}

    case effect do
      :authorize -> execute(state, reply, command)
      :guide -> guide(state, reply, :direct)
      :close -> reject(state, reply)
    end
  end

  # @cc [owner:ghuntley,label:security] audi-pty-diagnostic-only
  # PTY acknowledgement MUST only enable bounded setup guidance. It MUST NOT
  # allocate a terminal, authorize a VM, or permit a later exec to open a stream.
  def handle_ssh_msg({:ssh_cm, connection, {:pty, channel, reply, _}}, state) do
    {phase, effect} = State.step(state.phase, :pty)
    state = %{state | phase: phase, connection: connection, channel: channel}

    if effect == :acknowledge do
      :ssh_connection.reply_request(connection, reply, :success, channel)
      {:ok, %{state | pty: true}}
    else
      reject(state, reply)
    end
  end

  def handle_ssh_msg({:ssh_cm, connection, {:shell, channel, reply}}, state) do
    {phase, effect} = State.step(state.phase, :shell)
    state = %{state | phase: phase, connection: connection, channel: channel}
    if effect == :guide, do: guide(state, reply, :direct), else: reject(state, reply)
  end

  # @cc [owner:ghuntley,label:security] audi-ssh-stream-backpressure
  # Guest reads MUST use active-once. SSH receive credit MUST be returned only
  # after the bounded local send succeeds. Blocking sends MUST have a timeout;
  # independent lease expiry MUST still close the socket while a send blocks.
  def handle_ssh_msg({:ssh_cm, _, {:data, _, 0, bytes}}, %{socket: socket, eof: false} = state)
      when not is_nil(socket) do
    if active?(state) and byte_size(bytes) <= 65_536 and :gen_tcp.send(socket, bytes) == :ok do
      :ssh_connection.adjust_window(state.connection, state.channel, byte_size(bytes))
      {:ok, state}
    else
      finish(state, 1)
    end
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, _}}, %{socket: socket, eof: false} = state)
      when not is_nil(socket) do
    case :gen_tcp.shutdown(socket, :write) do
      :ok -> {:ok, %{state | eof: true}}
      _ -> finish(state, 1)
    end
  end

  def handle_ssh_msg({:ssh_cm, connection, {:env, channel, reply, _, _}}, state) do
    Audi.Events.emit("audi.ssh_denied", reason: :unsupported_request)
    :ssh_connection.reply_request(connection, reply, :failure, channel)
    {:ok, state}
  end

  def handle_ssh_msg(_, state), do: finish(state, 1)

  @impl true
  def terminate(_, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    if state.worker, do: Process.exit(elem(state.worker, 0), :kill)
    if state.renewal, do: Process.cancel_timer(state.renewal)
    :timer.cancel(state.setup)
    :ok
  end

  defp execute(state, reply, command) do
    with {:ok, label} <- command |> text() |> Request.parse(),
         {:ok, key} <- Proof.lookup(state.connection) do
      case open(state, key, label) do
        {:ok, opened, started_us} ->
          {phase, :relay} = State.step(state.phase, :opened)

          case acknowledge_exec(state, reply) do
            :ok ->
              Audi.Events.emit("audi.ssh_open",
                host_id: opened.grant.binding.host_id,
                vm_id: opened.grant.binding.vm_id,
                placement_id: opened.grant.binding.placement_id,
                session_id: opened.grant.binding.session_id,
                execution_epoch: opened.grant.binding.execution_epoch,
                generation: opened.grant.binding.generation
              )

              record_establishment(true, started_us)
              {:ok, %{opened | phase: phase}}

            _ ->
              record_establishment(false, started_us)
              finish(opened, 1)
          end

        _ ->
          guide(state, reply, :proxy)
      end
    else
      _ -> guide(state, reply, :proxy)
    end
  end

  # @cc [owner:ghuntley,label:security;reliability] audi-ssh-exec-acknowledgment
  # A failed SSH reply call MUST return failure to the establishment counter;
  # an exception or exit MUST NOT be mistaken for an acknowledged guest stream.
  defp acknowledge_exec(state, reply) do
    :ssh_connection.reply_request(state.connection, reply, :success, state.channel)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  # @cc [owner:ghuntley,label:protocol;security] audi-guidance-stderr-only
  # Guidance MUST use bounded extended-data stderr and a nonzero exit status.
  # Stdout is reserved for guest SSH bytes. Key status requires signature proof;
  # unavailable status MUST NOT be described as an unknown key. A handled exec
  # may acknowledge diagnostics, but MUST NOT imply a successful guest admission.
  defp guide(state, reply, mode) do
    {diagnosis, fingerprint} =
      case Proof.lookup(state.connection) do
        {:ok, key} ->
          result = invoke(state.config.backend, :key_status, [key])

          status =
            case result do
              {:ok, :unknown} -> :unknown
              {:ok, :recognized} -> if(mode == :proxy, do: :denied, else: :recognized)
              _ -> :unavailable
            end

          {status, key.fingerprint}

        _ ->
          {:unavailable, ""}
      end

    Audi.Events.emit("audi.ssh_denied", reason: :denied)
    :ssh_connection.reply_request(state.connection, reply, :success, state.channel)
    message = SSHOnboarding.guidance(diagnosis, fingerprint, state.config.public_origin, mode)
    message = SSHOnboarding.terminal_lines(message, state.pty)
    :ssh_connection.send(state.connection, state.channel, 1, message, 500)
    finish(state, 1)
  end

  defp reject(state, reply) do
    Audi.Events.emit("audi.ssh_denied", reason: :unsupported_request)
    :ssh_connection.reply_request(state.connection, reply, :failure, state.channel)
    finish(state, 1)
  end

  # @cc [owner:ghuntley,label:security;reliability] audi-ssh-source-owned-establishment
  # A valid current grant MAY enter the SSH establishment denominator only after
  # grant validation. Connector or guard failure then counts as failure; success
  # requires a connected guest socket and an acknowledged SSH exec request.
  # Invalid selectors, unproved keys and denied or malformed grants MUST NOT
  # add outcomes. No key, VM, account, command or session identifier is retained.
  defp open(state, key, label) do
    started_us = System.monotonic_time(:microsecond)
    started = now()

    case invoke(state.config.backend, :authorize, [key, label]) do
      {:ok, grant} ->
        if Request.grant?(grant, label, state.config.host_id),
          do: open_granted(state, grant, started, started_us),
          else: {:error, :denied}

      _ ->
        {:error, :denied}
    end
  end

  defp open_granted(state, grant, started, started_us) do
    Process.put(
      {__MODULE__, :slo_ticket},
      Overalls.RequestAccounting.Producer.admit(Audi.RequestRecorder)
    )

    with {:ok, guard} <-
           StreamGuard.start_link(
             owner: self(),
             binding: Request.authority_binding(grant),
             requested_at: started,
             ttl: grant.ttl
           ),
         {:ok, socket} <- invoke(state.config.backend, :connect, [grant.ticket, grant.binding]),
         true <- now() < started + grant.ttl,
         :ok <-
           :inet.setopts(socket, [
             :binary,
             packet: 0,
             active: :once,
             buffer: 32_768,
             send_timeout: 1000,
             send_timeout_close: true
           ]) do
      :timer.cancel(state.setup)

      Audi.Authority.HintRenewal.register(
        vm: Map.get(grant.binding, :vm_id),
        user: Map.get(grant, :user_id)
      )

      {:ok,
       schedule(
         %{state | grant: grant, guard: guard, socket: socket, deadline: started + grant.ttl},
         grant.ttl
       ), started_us}
    else
      _ ->
        record_establishment(false, started_us)
        {:error, :denied}
    end
  end

  defp elapsed_us(started_us),
    do: max(System.monotonic_time(:microsecond) - started_us, 0)

  @spec record_establishment(boolean(), integer()) :: :ok
  defp record_establishment(success, started_us) do
    ticket = Process.delete({__MODULE__, :slo_ticket}) || :unrecorded
    duration = elapsed_us(started_us)

    Overalls.RequestAccounting.Producer.complete(
      Audi.RequestRecorder,
      ticket,
      if(success, do: :success, else: :failure),
      duration
    )

    Audi.SLO.record_outcome(success, duration)
  end

  defp schedule(state, ttl),
    do: %{
      state
      | renewal: Process.send_after(self(), :renew, Audi.Authority.HintRenewal.delay(ttl))
    }

  defp invoke({module, config}, action, arguments) do
    apply(module, action, [config | arguments])
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp finish(state, status) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :ssh_connection.exit_status(state.connection, state.channel, status)
    :ssh_connection.send_eof(state.connection, state.channel)
    {phase, :close} = State.step(state.phase, :close)
    {:stop, state.channel, %{state | phase: phase}}
  end

  defp text(command) when is_binary(command) and byte_size(command) <= 96, do: command

  defp text(command) when is_list(command) and length(command) <= 96,
    do: :unicode.characters_to_binary(command)

  defp text(_), do: nil
  defp active?(state), do: is_integer(state.deadline) and now() < state.deadline
  defp now, do: System.monotonic_time(:millisecond)
end
