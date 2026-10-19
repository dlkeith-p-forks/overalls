defmodule MarshallWeb.TerminalLogFilter do
  @moduledoc "Keep terminal process diagnostics while excluding event bytes and crash state."
  @catalog Marshall.Events

  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(:marshall_terminal_privacy, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, :marshall_terminal_privacy}} -> :ok
    end
  end

  # @cc [owner:ghuntley,label:security] terminal-log-payload-redaction
  # filter/2 MUST replace tagged terminal diagnostics, including crash reports,
  # with fixed text and process/event context; untagged events MUST be left for
  # other filters. Catalogued events may additionally retain only their
  # declared typed metadata. Viewer and ticket refusal events may retain only
  # their respective closed reason atoms. No arbitrary reason, original
  # message, bytes or process state may survive redaction.
  @spec filter(map(), term()) :: map() | :ignore
  def filter(%{meta: %{marshall_terminal: true} = metadata} = event, _) do
    safe =
      metadata
      |> Map.take([:time, :pid, :gl, :domain, :event])
      |> Map.merge(Overalls.Diagnostics.Context.log_context(metadata))

    safe = Map.merge(safe, catalogued_metadata(metadata))

    safe =
      case metadata do
        %{event: "terminal.viewer_refused", reason: reason}
        when reason in [
               :authority,
               :authority_unconfirmed,
               :authority_login,
               :authority_session,
               :authority_host,
               :authority_writer,
               :authority_credential,
               :input_window,
               :output_window,
               :input_ack,
               :output_ack,
               :slow_viewer,
               :gateway_session,
               :gateway_unavailable,
               :gateway_ticket,
               :stream_unavailable,
               :attach_timeout,
               :attach_refused
             ] ->
          Map.put(safe, :reason, reason)

        %{event: "terminal.ticket_refused", reason: reason}
        when reason in [
               :unknown_session,
               :forbidden,
               :terminal_unavailable,
               :vm_deleted,
               :unavailable,
               :other
             ] ->
          Map.put(safe, :reason, reason)

        _ ->
          safe
      end

    %{
      event
      | msg: {:string, "Terminal process diagnostic (payload redacted)"},
        meta: safe
    }
  end

  def filter(_, _), do: :ignore

  @spec catalogued_metadata(map()) :: map()
  defp catalogued_metadata(%{event: name} = metadata) when is_binary(name) do
    metadata =
      if name in ["terminal.viewer_refused", "terminal.ticket_refused"],
        do: Map.delete(metadata, :reason),
        else: metadata

    case Overalls.Diagnostics.Events.Catalog.projection(@catalog, name) do
      %{metadata: declared} ->
        Overalls.Diagnostics.Events.Catalog.safe_metadata(declared, metadata)

      _ ->
        %{}
    end
  end

  defp catalogued_metadata(_), do: %{}
end
