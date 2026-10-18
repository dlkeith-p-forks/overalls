defmodule MarshallWeb.AdminElevation do
  @moduledoc "Bounded socket-local administrative continuations."

  use Gettext, backend: MarshallWeb.Gettext

  @type params :: %{String.t() => String.t() | %{String.t() => String.t()}}
  @type binding :: %{
          actor_id: String.t(),
          login_jti: String.t() | nil,
          view: module(),
          path: String.t() | nil,
          action: atom() | nil,
          host_id: String.t() | nil,
          campaign_id: String.t() | nil,
          job_id: String.t() | nil,
          request_id: String.t() | nil,
          retry_request_id: String.t() | nil
        }
  @type intent :: %{
          event: String.t(),
          params: params(),
          binding: binding(),
          nonce: String.t(),
          challenge_id: String.t() | nil,
          expires_at: integer()
        }

  @id_events ~w(revoke-sessions revoke-key revoke-session revoke-grant reset-mfa refresh remove relocate)
  @empty_events ~w(evacuate rotate-certificate retry)
  @spec action_labels() :: %{String.t() => String.t()}
  defp action_labels do
    %{
      "set-role" => gettext("change administrator access"),
      "revoke-sessions" => gettext("sign this account out everywhere"),
      "revoke-key" => gettext("revoke this SSH key"),
      "revoke-session" => gettext("close this SSH session"),
      "revoke-grant" => gettext("revoke this VM access"),
      "invite" => gettext("send this invitation"),
      "delete-user" => gettext("delete this user account"),
      "reset-mfa" => gettext("reset this account's passkeys"),
      "register" => gettext("add this Git mirror"),
      "refresh" => gettext("refresh this Git mirror"),
      "remove" => gettext("remove this Git mirror"),
      "evacuate" => gettext("start this node evacuation"),
      "control" => gettext("change this evacuation"),
      "approve" => gettext("approve this workload downtime"),
      "replan" => gettext("replan this workload move"),
      "lifecycle" => gettext("change this machine's state"),
      "relocate" => gettext("move this machine"),
      "rotate-certificate" => gettext("rotate the fleet certificate"),
      "admin-override" => gettext("open this machine with administrator access"),
      "configure" => gettext("change this node's admission settings"),
      "retry" => gettext("retry this background job")
    }
  end

  @doc "A static action label from the same closed administrative event grammar."
  @spec action_label(String.t()) :: String.t()
  def action_label(event), do: Map.fetch!(action_labels(), event)

  # @cc [owner:ghuntley,label:security;concurrency] admin-elevation-bounded-intent
  # Pending actions MUST retain only this closed event grammar, server-side and
  # for at most five minutes. Navigation/resource changes MUST invalidate their
  # binding. The browser's bounded button value is transport metadata and MUST
  # NOT enter the retained arguments. WebAuthn assertions MUST NOT choose the
  # action or its parameters.
  @spec normalize(String.t(), term()) :: {:ok, params()} | :error
  def normalize(event, params) when event in @id_events,
    do: fields(params, [{"id", :uuid}])

  def normalize(event, params) when event in @empty_events, do: fields(params, [])

  def normalize("set-role", params),
    do: fields(params, [{"id", :uuid}, {"enabled", ["true", "false"]}])

  def normalize("invite", params), do: fields(params, [{"email", 254}])

  def normalize("delete-user", params),
    do: fields(params, [{"user_id", :uuid}, {"confirmation", 254}])

  def normalize("control", params),
    do: fields(params, [{"command", ~w(pause continue resume retire)}])

  def normalize(event, params) when event in ~w(approve replan),
    do: fields(params, [{"id", :uuid}, {"key", 128}])

  def normalize("lifecycle", params),
    do: fields(params, [{"id", :uuid}, {"kind", ~w(start stop delete)}])

  def normalize("configure", params),
    do:
      fields(params, [
        {"enabled", ["true", "false"]},
        {"overhead_cores", :nonnegative},
        {"overhead_memory_bytes", :nonnegative}
      ])

  def normalize("register", %{"git" => params} = outer) when map_size(outer) == 1 do
    with {:ok, values} <- fields(params, [{"owner", 100}, {"repo", 100}]),
         do: {:ok, %{"git" => values}}
  end

  def normalize("admin-override", params),
    do: fields(params, [{"id", :uuid}, {"destination", ~w(details terminals resize)}])

  def normalize(_, _), do: :error

  @spec stage(String.t(), params(), Phoenix.LiveView.Socket.t()) :: intent()
  def stage(event, params, socket) do
    %{
      event: event,
      params: params,
      binding: socket_binding(socket),
      nonce: Ash.UUID.generate(),
      challenge_id: nil,
      expires_at: System.monotonic_time(:second) + 300
    }
  end

  @spec current?(intent(), Phoenix.LiveView.Socket.t()) :: boolean()
  def current?(intent, socket),
    do:
      intent.binding == socket_binding(socket) and
        System.monotonic_time(:second) < intent.expires_at

  @spec socket_binding(Phoenix.LiveView.Socket.t()) :: binding()
  defp socket_binding(socket) do
    %{
      actor_id: socket.assigns.current_user.id,
      login_jti: socket.private[:login_jti],
      view: socket.view,
      path: socket.private[:security_return_to],
      action: socket.assigns[:live_action],
      host_id: socket.assigns[:host_id],
      campaign_id: socket.assigns[:campaign] && socket.assigns.campaign.id,
      job_id: socket.assigns[:job_id],
      request_id: socket.assigns[:request_id],
      retry_request_id: socket.assigns[:retry_request_id]
    }
  end

  @spec fields(term(), [{String.t(), :uuid | :nonnegative | pos_integer() | [String.t()]}]) ::
          {:ok, params()} | :error
  defp fields(params, schema) when is_map(params) do
    keys = Enum.map(schema, &elem(&1, 0))
    transport_value = params["value"]
    params = Map.delete(params, "value")

    if (is_nil(transport_value) or
          (is_binary(transport_value) and byte_size(transport_value) <= 256)) and
         Map.keys(params) -- keys == [] do
      Enum.reduce_while(schema, {:ok, %{}}, fn {key, type}, {:ok, values} ->
        case value(params[key], type) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(values, key, normalized)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp fields(_, _), do: :error

  @spec value(term(), :uuid | :nonnegative | pos_integer() | [String.t()]) ::
          {:ok, String.t()} | :error
  defp value(value, :uuid) do
    if OverallsProtocol.uuid?(value), do: {:ok, value}, else: :error
  end

  defp value(value, :nonnegative) when is_binary(value) and byte_size(value) in 1..20 do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, Integer.to_string(integer)}
      _ -> :error
    end
  end

  defp value(value, maximum) when is_integer(maximum) and is_binary(value) do
    if byte_size(value) in 1..maximum and String.valid?(value) and
         not String.contains?(value, ["\r", "\n", "\0"]),
       do: {:ok, value},
       else: :error
  end

  defp value(value, allowed) when is_list(allowed) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp value(_, _), do: :error
end
