defmodule Marshall.Mailer.LogFilter do
  @moduledoc "Redact mail process diagnostics before any logger handler sees payloads."
  @catalog Marshall.Events

  # Mirrors MarshallWeb.IngressAPI.unavailable_reasons/0; a test pins equality.
  @control_reasons [
    :unavailable,
    :temporarily_unavailable,
    :approval_unavailable,
    :image_unavailable,
    :key_unavailable,
    :invalid_binding,
    :invalid_state,
    :invalid_peer_token,
    :rejected,
    :unexpected
  ]

  # Events whose reasons are restricted to the reviewed sets above; the
  # generic catalogue path must not widen them.
  @restricted_events ["galileo.authorization_denied", "audi.control_unavailable"]

  @doc false
  @spec control_reasons() :: [atom()]
  def control_reasons, do: @control_reasons

  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(:marshall_mail_privacy, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, :marshall_mail_privacy}} -> :ok
    end
  end

  # @cc [owner:ghuntley,label:security] mail-tagged-diagnostics-redacted
  # Mail/authentication-tagged log events MUST replace all message content and
  # retain only process context, the event name and validated trace context.
  # Authentication-tagged events named in Marshall.Events' reviewed catalog MAY
  # additionally keep exactly their declared metadata keys whose values
  # re-validate as their declared type (uuid, atom, bounded int, pid); undeclared
  # keys and invalid values are dropped. Authentication-tagged Galileo
  # authorization-denied and Audi control-unavailable events may retain only
  # their reviewed closed reason atoms. A simultaneous mail tag MUST retain mail
  # redaction precedence, suppress catalog metadata and drop the reason.
  # Provider errors, tokens, credentials and process state MUST NOT survive into
  # handler output. The catalog has no string type, so no payload can pass this
  # way.
  @spec filter(map(), term()) :: map() | :ignore
  def filter(%{meta: %{marshall_mail: true} = metadata} = event, _) do
    redact(event, metadata, "Mail process diagnostic (payload redacted)")
  end

  def filter(%{meta: %{marshall_authentication: true} = metadata} = event, _) do
    filtered =
      redact(event, metadata, "Authentication process diagnostic (payload redacted)")

    case metadata do
      %{event: "galileo.authorization_denied", reason: reason}
      when reason in [:unauthorized, :invalid_request, :peer_unreachable, :authorization_invalid] ->
        put_in(filtered, [:meta, :reason], reason)

      %{event: "audi.control_unavailable", reason: reason} when reason in @control_reasons ->
        put_in(filtered, [:meta, :reason], reason)

      %{event: name} when name in @restricted_events ->
        filtered

      %{event: name} when is_binary(name) ->
        catalogued(filtered, metadata, name)

      _ ->
        filtered
    end
  end

  def filter(_, _), do: :ignore

  defp catalogued(filtered, metadata, name) do
    case Overalls.Diagnostics.Events.Catalog.projection(@catalog, name) do
      %{message: message, metadata: declared} ->
        kept = Overalls.Diagnostics.Events.Catalog.safe_metadata(declared, metadata)
        %{filtered | msg: {:string, message}, meta: Map.merge(filtered.meta, kept)}

      _ ->
        filtered
    end
  end

  defp redact(event, metadata, message) do
    %{
      event
      | msg: {:string, message},
        meta:
          metadata
          |> Map.take([:time, :pid, :gl, :domain, :event])
          |> Map.merge(Overalls.Diagnostics.Context.log_context(metadata))
    }
  end

  @spec private((-> result)) :: result when result: term()
  def private(fun) do
    original = Logger.metadata()
    Logger.metadata(marshall_mail: true)

    try do
      fun.()
    after
      Logger.reset_metadata(original)
    end
  end
end
