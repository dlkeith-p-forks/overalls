defmodule Porsche.Runner do
  @moduledoc "One command admission followed by authorized, receipt-correlated polling."
  alias OverallsProtocol.SSHCommand
  alias Porsche.Client
  require Porsche.Events

  @type result :: %{exit_status: non_neg_integer(), response: map(), close: boolean()}
  @type request :: (Client.t(), binary(), map(), keyword() -> {:ok, map()} | {:error, atom()})

  # @cc [owner:ghuntley,label:recovery;authorization] porsche-wait-only-observes
  # A command MUST be submitted at most once per invocation, using a request ID
  # allocated before submission for every mutation. Waiting MUST use authorized
  # request-show commands and correlate receipt and operation identity. Timeout,
  # transport failure or process death MUST NOT submit cancellation or repeat a
  # mutation. Only an explicit succeeded receipt can establish physical success.
  @spec run(Client.t(), binary(), term(), keyword()) :: result()
  def run(client, session, text, options \\ []) do
    Porsche.Observability.measure(:ssh, fn ->
      case SSHCommand.parse(text) do
        {:ok, command} -> run_validated(client, session, command, options)
        {:error, reason} -> failure(reason, nil, 2)
      end
    end)
  end

  # @cc [owner:ghuntley,label:security] porsche-structured-secret-dispatch
  # Commands containing stdin-provided credentials MUST be dispatched as an
  # already validated structure. Porsche MUST NOT rebuild shell text containing
  # the secret or expose that structure in diagnostics.
  @spec run_command(Client.t(), binary(), SSHCommand.t(), keyword()) :: result()
  def run_command(client, session, command, options \\ []) do
    Overalls.Diagnostics.Tracing.with_span("porsche.ssh.dispatch", [], fn ->
      run_traced_command(client, session, command, options)
    end)
  end

  @spec run_traced_command(Client.t(), binary(), SSHCommand.t(), keyword()) :: result()
  defp run_traced_command(client, session, command, options) do
    Porsche.Observability.measure(:ssh, fn ->
      case SSHCommand.validate(%{
             "version" => command.version,
             "command" => command.command,
             "arguments" => command.arguments,
             "options" => command.options
           }) do
        {:ok, validated} -> run_validated(client, session, validated, options)
        {:error, reason} -> failure(reason, nil, 2)
      end
    end)
  end

  defp run_validated(client, session, command, options) do
    if SSHCommand.stdin_secret?(command),
      do: failure(:stdin_secret_required, nil, 2),
      else: execute(client, session, command, options)
  end

  defp execute(client, session, command, options) do
    command = identify(command)
    id = receipt_id(command)
    now = Keyword.get(options, :now, fn -> System.monotonic_time(:millisecond) end)
    seconds = command.options |> Map.get("timeout", "120") |> String.to_integer()

    context = %{
      client: client,
      session: session,
      request: Keyword.get(options, :request, &Client.request/4),
      now: now,
      sleep: Keyword.get(options, :sleep, &Process.sleep/1),
      progress: Keyword.get(options, :progress, fn _ -> :ok end),
      deadline: now.() + seconds * 1000,
      id: id
    }

    # This reaches only the channel's progress stream, never application logs.
    if SSHCommand.mutation?(command.command),
      do: context.progress.(%{event: :submitting, request_id: id})

    with {:ok, response} <- submit(context, command),
         :ok <- validate(response, id),
         :ok <- validate_kind(response, command.command) do
      if SSHCommand.physical?(command.command) and command.options["no-wait"] != true do
        await(context, response)
      else
        result(response, command.command == "exit")
      end
    else
      {:error, reason} -> unavailable(reason, id, error_status(reason))
    end
  end

  defp identify(command) do
    if SSHCommand.mutation?(command.command) do
      update_in(
        command.options,
        &Map.put_new_lazy(&1, "request-id", fn ->
          "porsche-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        end)
      )
    else
      command
    end
  end

  defp receipt_id(%{command: "request show", arguments: [id]}), do: id
  defp receipt_id(command), do: command.options["request-id"]

  defp submit(context, command) do
    message = %{
      "version" => 1,
      "session_token" => context.session,
      "command" => %{
        "version" => 1,
        "command" => command.command,
        "arguments" => command.arguments,
        "options" => command.options
      }
    }

    context.request.(context.client, "commands", message,
      timeout: max(1, min(5000, context.deadline - context.now.()))
    )
  end

  defp await(context, %{"status" => "accepted"} = receipt) do
    remaining = context.deadline - context.now.()

    if remaining <= 0 do
      %{exit_status: 4, response: Map.put(receipt, "wait_status", "timed_out"), close: false}
    else
      context.progress.(%{event: :waiting, request_id: context.id})
      context.sleep.(min(1000, remaining))
      poll(context, receipt)
    end
  end

  defp await(_context, receipt), do: result(receipt, false)

  @transient_poll [:transport_error, :temporarily_unavailable, :rate_limited, :http_error]

  defp poll(context, receipt) do
    if context.now.() >= context.deadline do
      await(context, receipt)
    else
      command = %{version: 1, command: "request show", arguments: [context.id], options: %{}}

      with {:ok, response} <- submit(context, command),
           :ok <- validate(response, context.id),
           true <- response["operation_id"] == receipt["operation_id"] do
        await(context, response)
      else
        # @cc [owner:ghuntley,label:recovery] porsche-wait-tolerates-transient-polls
        # A transient poll failure (transport, 503, 429, other non-2xx) MUST NOT
        # end a wait before its deadline: the admitted request is unaffected, so
        # keep the last receipt and poll again (ADR-0140: slowness is not failure).
        {:error, reason} when reason in @transient_poll ->
          await(context, receipt)

        {:error, reason} ->
          unavailable(reason, context.id, error_status(reason))

        _ ->
          unavailable(:invalid_response, context.id, 5)
      end
    end
  end

  defp validate(%{"version" => 1, "status" => "succeeded", "result" => result} = response, nil)
       when map_size(response) == 3 and is_map(result), do: :ok

  defp validate(
         %{
           "version" => 1,
           "request_id" => id,
           "status" => status,
           "operation_id" => operation,
           "result" => result
         } = response,
         id
       )
       when is_binary(id) and map_size(response) == 5 and is_map(result) and
              status in ["accepted", "succeeded", "failed", "superseded"] do
    if (is_nil(operation) and status == "succeeded") or OverallsProtocol.uuid?(operation),
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate(_, _), do: {:error, :invalid_response}

  defp validate_kind(response, command) do
    valid =
      cond do
        SSHCommand.physical?(command) ->
          OverallsProtocol.uuid?(response["operation_id"])

        SSHCommand.mutation?(command) ->
          response["operation_id"] == nil and response["status"] == "succeeded"

        true ->
          true
      end

    if valid, do: :ok, else: {:error, :invalid_response}
  end

  defp result(response, close) do
    status = if response["status"] in ["succeeded", "accepted"], do: 0, else: 1
    %{exit_status: status, response: response, close: close}
  end

  defp error_status(reason) when reason in [:unauthorized, :forbidden], do: 3

  defp error_status(reason) when reason in [:invalid_request, :not_found], do: 2

  defp error_status(reason), do: if(Client.conflict?(reason), do: 2, else: 5)

  # @cc [owner:ghuntley,label:security] porsche-command-unavailable-closed-reason
  # Command dispatch failures MUST be logged with only the closed error atom;
  # commands, arguments, options, receipts and response bodies MUST NOT be
  # logged.
  defp unavailable(reason, id, status) do
    Porsche.Events.emit("porsche.command_unavailable", reason: reason)
    failure(reason, id, status)
  end

  defp failure(reason, id, status) do
    response = %{"version" => 1, "status" => "error", "error" => Atom.to_string(reason)}
    response = if id, do: Map.put(response, "request_id", id), else: response
    response = if hint = hint(reason), do: Map.put(response, "hint", hint), else: response
    %{exit_status: status, response: response, close: false}
  end

  # Fixed next-step text for refusals a user can resolve themselves; it carries
  # no remote or command text.
  @spec hint(atom()) :: String.t() | nil
  defp hint(:machine_pinned),
    do: "The owner has this machine pinned; unpin it first: unpin MACHINE"

  defp hint(:machine_failed), do: "A failed machine cannot be pinned; an existing pin can still be removed."
  defp hint(:pin_limit), do: "You already hold the maximum number of pins; unpin one first."
  defp hint(_), do: nil
end
