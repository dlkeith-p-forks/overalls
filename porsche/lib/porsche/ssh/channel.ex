defmodule Porsche.SSH.Channel do
  @moduledoc "Management-only exec and interactive SSH channels."
  @behaviour :ssh_server_channel
  use Gettext, backend: Porsche.Gettext
  alias Porsche.{Connection, Runner}
  alias Porsche.SSH.{Display, Input, Output}
  alias OverallsProtocol.SSHCommand

  @impl true
  def init([config | _]) do
    :logger.update_process_metadata(%{porsche_private: true})

    {:ok,
     %{
       config: config,
       connection: nil,
       channel: nil,
       mode: nil,
       pty: false,
       width: 80,
       height: 24,
       screen: nil,
       task: nil,
       job: nil,
       json: false,
       input: %Input{},
       stdin_command: nil,
       stdin_secret: "",
       eof: false
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel, connection}, state),
    do: {:ok, %{state | channel: channel, connection: connection}}

  def handle_msg({:progress, job, progress}, %{job: job} = state) do
    state = clear_prompt(state)
    write(state, 1, Output.progress(progress))
    {:ok, show_prompt(state)}
  end

  def handle_msg({reference, result}, %{task: %Task{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    state = clear_prompt(%{state | task: nil, job: nil})

    case Connection.snapshot(state.connection) do
      {:ok, session} -> Porsche.Locale.put_locale(session)
      _ -> Porsche.Locale.put_locale(nil)
    end

    context = if state.mode == :exec, do: {:exec, state.config.public_origin}, else: :interactive
    if result.response, do: write(state, 0, Output.render(result.response, state.json, context))

    if state.mode == :exec or result.close do
      stop(state, result.exit_status)
    else
      advance(state)
    end
  end

  def handle_msg(
        {:DOWN, reference, :process, _pid, _reason},
        %{task: %Task{ref: reference}} = state
      ),
      do: fail(%{state | task: nil, job: nil}, :temporarily_unavailable, 5)

  def handle_msg(_, state), do: {:ok, state}

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, connection,
         {:pty, channel, reply, {_term, width, height, _pixels, _ypixels, _modes}}},
        %{mode: nil} = state
      ) do
    :ssh_connection.reply_request(connection, reply, :success, channel)

    {:ok,
     %{
       state
       | pty: true,
         width: valid_width(width),
         height: valid_height(height),
         channel: channel,
         connection: connection
     }}
  end

  def handle_ssh_msg({:ssh_cm, connection, {:exec, channel, reply, text}}, %{mode: nil} = state) do
    :ssh_connection.reply_request(connection, reply, :success, channel)
    state = %{state | mode: :exec, connection: connection, channel: channel}

    case :unicode.characters_to_binary(text) do
      command when is_binary(command) -> start_exec(state, command)
      _ -> fail(state, :invalid_command, 2)
    end
  end

  def handle_ssh_msg({:ssh_cm, connection, {:shell, channel, reply}}, %{mode: nil} = state) do
    :ssh_connection.reply_request(connection, reply, :success, channel)
    state = %{state | mode: :interactive, connection: connection, channel: channel}

    case Connection.snapshot(connection) do
      {:ok, session} -> Porsche.Locale.put_locale(session)
      _ -> Porsche.Locale.put_locale(nil)
    end

    write(
      state,
      0,
      banner() <>
        "\n" <>
        dgettext("sessions", "Porsche machine management. Type help.") <>
        "\n" <>
        dgettext("sessions", "Docs:") <>
        " " <>
        state.config.public_origin <> "/docs\n"
    )

    start(state, :welcome)
  end

  def handle_ssh_msg({:ssh_cm, _, {:data, _, _, _}}, %{eof: true} = state),
    do: fail(state, :unexpected_input, 2)

  def handle_ssh_msg(
        {:ssh_cm, connection, {:data, channel, 0, bytes}},
        %{mode: :exec, stdin_command: command} = state
      )
      when not is_nil(command) do
    :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
    secret = state.stdin_secret <> bytes

    if byte_size(secret) <= 4098,
      do: {:ok, %{state | stdin_secret: secret}},
      else: fail(%{state | stdin_secret: ""}, :invalid_command, 2)
  end

  def handle_ssh_msg(
        {:ssh_cm, connection, {:data, channel, 0, bytes}},
        %{mode: :interactive} = state
      ) do
    case Input.feed(state.input, bytes) do
      {:ok, input, submitted} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
        state = clear_prompt(state)

        if state.pty do
          for line <- submitted, do: write(state, 0, Display.submitted(line, state.width))
        end

        advance(%{state | input: input}, state.pty)

      :close ->
        stop(state, 0)

      :interrupt ->
        stop(state, 130)

      {:error, reason} ->
        fail(state, reason, 2)
    end
  end

  def handle_ssh_msg(
        {:ssh_cm, _, {:eof, _}},
        %{mode: :exec, stdin_command: command} = state
      )
      when not is_nil(command) do
    secret = trim_secret_line(state.stdin_secret)
    state = %{state | eof: true, stdin_secret: "", stdin_command: nil}

    case SSHCommand.put_stdin_secret(command, secret) do
      {:ok, validated} -> start(state, {:command, validated})
      {:error, _} -> fail(state, :invalid_command, 2)
    end
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, _}}, state),
    do: advance(%{state | eof: true, input: Input.finish(state.input)})

  def handle_ssh_msg({:ssh_cm, _, {:signal, _, _}}, state), do: stop(state, 130)

  def handle_ssh_msg({:ssh_cm, _, {:window_change, _, width, height, _, _}}, state) do
    state = clear_prompt(state)
    {:ok, show_prompt(%{state | width: valid_width(width), height: valid_height(height)})}
  end

  def handle_ssh_msg({:ssh_cm, connection, {:env, channel, reply, _, _}}, state) do
    :ssh_connection.reply_request(connection, reply, :failure, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, connection, {:pty, channel, reply, _}}, state) do
    :ssh_connection.reply_request(connection, reply, :failure, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, connection, {:exec, channel, reply, _}}, state) do
    :ssh_connection.reply_request(connection, reply, :failure, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, connection, {:shell, channel, reply}}, state) do
    :ssh_connection.reply_request(connection, reply, :failure, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:data, _, _, _}}, state), do: fail(state, :unexpected_input, 2)
  def handle_ssh_msg(_, state), do: {:ok, state}

  # @cc [owner:ghuntley,label:security;recovery] porsche-channel-no-domain-cancellation
  # Closing a channel MUST stop only its transient worker. It MUST NOT send
  # cancellation for admitted domain work. Every management command MUST use
  # the shared parser and Marshall session authority; no OS shell is available.
  @impl true
  def terminate(_, %{task: %Task{pid: pid}}), do: Process.exit(pid, :shutdown)
  def terminate(_, _), do: :ok

  defp advance(state, prompt \\ true)
  defp advance(%{task: task} = state, _) when not is_nil(task), do: {:ok, show_prompt(state)}

  defp advance(%{mode: :interactive} = state, prompt) do
    case Input.take(state.input) do
      {:line, "", input} ->
        advance(%{state | input: input})

      {:line, text, input} ->
        start(%{state | input: input}, text)

      :empty ->
        if state.eof do
          stop(state, 0)
        else
          state = if prompt, do: show_prompt(state), else: state
          {:ok, state}
        end
    end
  end

  defp advance(state, _), do: {:ok, state}

  defp start_exec(state, text) do
    case SSHCommand.parse(text) do
      {:ok, command} ->
        if SSHCommand.stdin_secret?(command),
          do: {:ok, %{state | stdin_command: command, json: command.options["json"] == true}},
          else: start(state, {:command, command})

      {:error, reason} ->
        fail(state, reason, 2)
    end
  end

  defp start(state, text) do
    owner = self()
    job = make_ref()

    json =
      case parsed_command(text) do
        {:ok, command} -> command.options["json"] == true
        _ -> false
      end

    task =
      Task.Supervisor.async_nolink(Porsche.SSH.Commands, fn ->
        :logger.update_process_metadata(%{porsche_private: true})

        execute(state, text, fn progress ->
          if Process.alive?(owner),
            do: send(owner, {:progress, job, progress}),
            else: exit(:normal)
        end)
      end)

    {:ok, show_prompt(%{state | task: task, job: job, json: json})}
  rescue
    _ -> fail(state, :temporarily_unavailable, 5)
  end

  defp execute(state, text, progress) do
    case Connection.snapshot(state.connection) do
      {:ok, %{"status" => "pending"} = session} ->
        %{
          exit_status: 3,
          close: false,
          response: %{
            "version" => 1,
            "status" => "approval_required",
            "fingerprint" => session["fingerprint"],
            "approval_url" => state.config.public_origin <> session["approval_path"],
            "message" => "Approve this key in your browser, then retry the command."
          }
        }

      {:ok, %{"status" => "authenticated"}} when text == :welcome ->
        %{exit_status: 0, close: false, response: nil}

      {:ok, %{"session_token" => token} = session} ->
        Porsche.Locale.put_locale(session)
        run(state, token, text, progress)

      {:error, reason} ->
        error(reason, 3)
    end
  end

  defp run(state, token, {:command, command}, progress) do
    Runner.run_command(state.config.client, token, command,
      progress: progress,
      request: state.config.request
    )
  end

  defp run(state, token, text, progress) do
    Runner.run(state.config.client, token, text,
      progress: progress,
      request: state.config.request
    )
  end

  defp parsed_command({:command, command}), do: {:ok, command}
  defp parsed_command(text), do: SSHCommand.parse(text)

  defp trim_secret_line(value) do
    cond do
      String.ends_with?(value, "\r\n") -> binary_part(value, 0, byte_size(value) - 2)
      String.ends_with?(value, "\n") -> binary_part(value, 0, byte_size(value) - 1)
      true -> value
    end
  end

  defp fail(state, reason, status) do
    state = clear_prompt(state)
    write(state, 0, Output.render(error(reason, status).response, state.json))
    stop(state, status)
  end

  defp error(reason, status),
    do: %{
      exit_status: status,
      close: false,
      response: %{"version" => 1, "status" => "error", "error" => Atom.to_string(reason)}
    }

  # @cc [owner:ghuntley,label:protocol] porsche-interactive-banner
  # The static banner MUST appear once per interactive shell and never in exec.
  defp banner do
    ~S"""
     _   _ _   _
    | |_(_) |_| |_ ___ _ _  ___
    | / / |  _|  _/ -_) ' \(_-<
    |_\_\_|\__|\__\___|_||_/__/
    """
  end

  defp valid_width(width) when is_integer(width) and width > 0, do: min(width, 4096)
  defp valid_width(_), do: 80
  defp valid_height(height) when is_integer(height) and height > 0, do: min(height, 4096)
  defp valid_height(_), do: 24

  defp clear_prompt(%{pty: true, screen: row} = state) do
    write(state, 0, Display.clear(row))
    %{state | screen: nil}
  end

  defp clear_prompt(state), do: state

  defp show_prompt(%{mode: :interactive, pty: true, screen: nil} = state) do
    if is_nil(state.task) or state.input.buffer != "" do
      {bytes, row} = Display.render(state.input, state.width, state.height)
      write(state, 0, bytes)
      %{state | screen: row}
    else
      state
    end
  end

  defp show_prompt(%{mode: :interactive, pty: false, task: nil} = state) do
    write(state, 0, "porsche> ")
    state
  end

  defp show_prompt(state), do: state

  # @cc [owner:ghuntley,label:protocol] porsche-pty-line-endings
  # Every PTY output stream MUST use CRLF line endings without doubling an
  # existing carriage return. Non-PTY output MUST preserve its original bytes.
  defp write(state, stream, bytes) do
    bytes = OverallsProtocol.SSHOnboarding.terminal_lines(bytes, state.pty)

    case :ssh_connection.send(state.connection, state.channel, stream, bytes, 5000) do
      :ok -> :ok
      _ -> exit(:normal)
    end
  end

  defp stop(state, status) do
    :ssh_connection.exit_status(state.connection, state.channel, status)
    :ssh_connection.send_eof(state.connection, state.channel)
    {:stop, state.channel, state}
  end
end
