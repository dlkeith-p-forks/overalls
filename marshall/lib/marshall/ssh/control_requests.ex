defmodule Marshall.SSH.ControlRequests do
  @moduledoc """
  Porsche's closed gateway requests, shared by the HTTPS routes and the
  control WebSocket (ADR-0142).

  `handle/3` decodes a versioned document and calls the gateway domain action
  with the gateway credential, which every action authenticates again.
  `classify/1` maps any result to the success document or to its HTTPS status
  class and closed error name, emitting the same refusal events for both
  transports. The lyra host-certificate route stays HTTPS-only.
  """
  require Marshall.Events

  @routes ["ready", "sessions", "session", "close", "commands"]

  @doc "The routes both transports serve."
  @spec routes() :: [String.t()]
  def routes, do: @routes

  @doc "Handles one decoded, versioned request document for `route`."
  @spec handle(String.t(), binary(), term()) :: {:ok, map()} | {:error, term()}
  def handle(route, token, decoded) when route in @routes do
    with {:ok, params} <- OverallsProtocol.SSHManagement.request(route, decoded) do
      params = Map.put(params, :gateway_token, token)
      actor = Marshall.Authorization.SystemActor.compute()

      case route do
        "ready" -> Marshall.SSH.gateway_ready(params, actor: actor)
        "sessions" -> Marshall.SSH.open_session(params, actor: actor)
        "session" -> Marshall.SSH.session_status(params, actor: actor)
        "close" -> Marshall.SSH.close_session(params, actor: actor)
        "commands" -> Marshall.SSH.execute(params, actor: actor)
      end
    end
  rescue
    _ -> {:error, :temporarily_unavailable}
  end

  def handle(_route, _token, _decoded), do: {:error, :invalid_request}

  @doc "The success document, or the HTTPS status class and closed error name."
  @spec classify(term()) :: {:ok, map()} | {:error, pos_integer(), String.t()}
  def classify({:ok, result}), do: {:ok, result}

  def classify({:error, %Marshall.SSH.Error{reason: reason}}),
    do: classify({:error, reason})

  def classify({:error, %Marshall.Compute.Error{reason: reason}}),
    do: classify({:error, reason})

  def classify({:error, %Ash.Error.Invalid{errors: [error]}}),
    do: classify({:error, error})

  def classify({:error, %Ash.Error.Forbidden{}}), do: classify({:error, :forbidden})

  # @cc [owner:ghuntley,label:security;product] ssh-profile-policy-refusal
  # Customer sharing policy rejection MUST use the existing forbidden response.
  # A known immutable-profile refusal MUST NOT be reported as transient service
  # unavailability or expose domain/error details through the gateway.
  def classify({:error, reason}) when reason in [:forbidden, :sharing_not_allowed],
    do: {:error, 403, "forbidden"}

  # @cc [owner:ghuntley,label:product;security] ssh-api-permanent-team-refusals
  # Closed Teams name/state conflicts MUST return 409 conflict, missing team or
  # transfer references 404 not_found, and absent membership 403 forbidden.
  # These permanent refusals MUST NOT become retryable 503 failures. Unexpected
  # exceptions MUST retain the opaque unavailable response below.
  def classify({:error, reason})
      when reason in [:team_name_taken, :transfer_pending, :invalid_transition],
      do: {:error, 409, "conflict"}

  def classify({:error, reason}) when reason in [:unknown_team, :unknown_transfer],
    do: {:error, 404, "not_found"}

  def classify({:error, :not_a_member}), do: classify({:error, :forbidden})

  def classify({:error, reason}) when reason in [:request_not_found, :key_not_found],
    do: {:error, 404, Atom.to_string(reason)}

  # @cc [owner:ghuntley,label:observability;security] ssh-api-closed-refusal-log
  # Expected admission refusals MUST use an event from the finite public reason
  # set; command text, credentials and arbitrary errors MUST NOT be logged.
  def classify({:error, reason})
      when reason in [
             :idempotency_conflict,
             :clone_already_published,
             :clone_not_retryable,
             :clone_in_progress,
             :name_unavailable,
             :insufficient_capacity,
             :image_unavailable,
             :image_requirements_not_met,
             :invalid_vm_size,
             :host_unavailable,
             :vm_deleted,
             :machine_pinned,
             :pin_limit,
             :workload_not_stable,
             :source_unavailable,
             :transfer_busy,
             :source_cleanup_pending,
             :resize_in_progress,
             :resize_not_retryable,
             :resize_not_cancellable,
             :stop_unconfirmed,
             :stale_generation,
             :relocation_in_progress,
             :relocation_committed,
             :relocation_finished,
             :relocation_retry_unavailable,
             :placement_changed,
             :disk_not_reserved,
             :generation_exhausted,
             :owner_protected,
             :recipient_not_registered,
             :workspace_source_not_allowed,
             :workspace_source_unavailable,
             :invalid_workspace_source
           ] do
    Marshall.Events.emit("api.request_unauthorized", reason: reason)
    {:error, 409, Atom.to_string(reason)}
  end

  def classify({:error, reason}) when reason in [:unauthorized, :approval_required] do
    Marshall.Events.emit("api.request_unauthorized", reason: reason)
    {:error, 401, Atom.to_string(reason)}
  end

  def classify({:error, :https_required}), do: {:error, 403, "https_required"}

  def classify({:error, :message_too_large}),
    do: {:error, 413, "message_too_large"}

  def classify({:error, :unsupported_version}),
    do: {:error, 426, "unsupported_version"}

  def classify({:error, reason}) when reason in [:session_limit, :approval_limit],
    do: {:error, 429, Atom.to_string(reason)}

  def classify({:error, reason})
      when reason in [:invalid_request, :invalid_public_key, :invalid_command],
      do: {:error, 400, Atom.to_string(reason)}

  # @cc [owner:ghuntley,label:security] ssh-api-opaque-errors
  # Unexpected failures MUST expose only a fixed response and event, never the
  # exception, request, key, token or database parameters.
  def classify(_result) do
    Marshall.Events.emit("ssh.request_unavailable", [])
    {:error, 503, "temporarily_unavailable"}
  end
end
