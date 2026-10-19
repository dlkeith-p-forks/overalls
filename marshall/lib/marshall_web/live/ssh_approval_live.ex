defmodule MarshallWeb.SSHApprovalLive do
  use MarshallWeb, :live_view
  alias Marshall.SSH
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       approval: nil,
       approval_token: nil,
       approved_link: nil,
       form: to_form(%{"label" => ""}, as: :key)
     )}
  end

  @impl true
  def handle_params(%{"token" => token}, _, socket) do
    case SSH.inspect_approval(%{token: token}, actor: socket.assigns.current_user) do
      {:ok, approval} -> {:noreply, assign(socket, approval: approval, approval_token: token)}
      {:error, _} -> {:noreply, unavailable(socket)}
    end
  end

  # @cc [owner:ghuntley,label:security] browser-ssh-approval-explicit
  # Only an explicit authenticated form event MAY consume the displayed approval.
  # The action MUST use the route-bound token and current actor, never client
  # ownership/token fields; replays and stale approval forms MUST fail closed.

  # @cc [owner:ghuntley,label:product;security] ssh-approval-open-mila
  # After a successful approval the page MUST stay put and offer an "Open Mila"
  # link built by Marshall.AppRoutes for the approved session's UUID only; the
  # link MUST NOT carry the approval token, fingerprint or any credential, and
  # no link is shown before or without a successful approval.
  @impl true
  def handle_event("approve", %{"key" => params}, %{assigns: %{approval_token: token}} = socket)
      when is_map(params) and is_binary(token) do
    case SSH.approve_key(%{token: token, label: Map.get(params, "label", "")},
           actor: socket.assigns.current_user
         ) do
      {:ok, %{session_id: session_id}} ->
        {:noreply,
         socket
         |> assign(
           approval: nil,
           approval_token: nil,
           approved_link: Marshall.AppRoutes.link({:ssh_approved, session_id})
         )
         |> put_flash(
           :info,
           dgettext("ssh", "SSH key approved. You can return to your SSH client.")
         )}

      {:error, _} ->
        {:noreply, unavailable(socket)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, unavailable(socket)}

  defp unavailable(socket) do
    socket
    |> assign(approval: nil, approval_token: nil)
    |> put_flash(
      :error,
      dgettext(
        "ssh",
        "This SSH approval is unavailable or has expired. Start a new SSH connection to try again."
      )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="ssh"
    >
      <section class="stack">
        <h1>{dgettext("ssh", "Approve SSH key")}</h1>
        <.form :if={@approval} for={@form} id="ssh-approval-form" phx-submit="approve" class="panel">
          <p>
            {dgettext(
              "ssh",
              "Approve this key only if you started the SSH connection and its fingerprint matches your SSH client."
            )}
          </p>
          <pre id="ssh-approval-fingerprint"><code>{@approval.fingerprint}</code></pre>
          <p class="muted">
            {dgettext(
              "ssh",
              "This key will sign in as %{value1}. It can manage machines according to your account's permissions.",
              value1: @current_user.email
            )}
          </p>
          <.input
            field={@form[:label]}
            label={dgettext("ssh", "Label (optional)")}
            maxlength="128"
            placeholder={dgettext("ssh", "My laptop")}
          />
          <Layouts.action
            tone="primary"
            id="approve-ssh-key"
            type="submit"
            phx-disable-with={dgettext("ssh", "Approving…")}
          >
            {dgettext("ssh", "Approve key")}
          </Layouts.action>
        </.form>
        <section :if={@approved_link} id="ssh-approval-approved" class="panel">
          <p>{dgettext("ssh", "SSH key approved. You can return to your SSH client.")}</p>
          <p>
            <a id="ssh-approval-open-mila" href={@approved_link}>{dgettext("ssh", "Open Mila")}</a>
          </p>
        </section>
        <p>
          <.link navigate={~p"/settings#ssh-keys"}>{dgettext("ssh", "Manage your SSH keys")}</.link>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
