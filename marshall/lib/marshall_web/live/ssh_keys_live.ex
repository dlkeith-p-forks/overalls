defmodule MarshallWeb.SSHKeysLive do
  use MarshallWeb, :live_view
  alias Marshall.SSH
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket) do
    {:ok, socket |> assign(keys: []) |> reset_form() |> refresh()}
  end

  # @cc [owner:ghuntley,label:security] browser-key-account-authority
  # Key actions MUST use the freshly authenticated socket user, never an owner
  # supplied by the form. Submitted key material MUST be cleared after attempts
  # and MUST NOT be reflected in diagnostics or error messages.
  @impl true
  def handle_event("add", %{"key" => params}, socket) when is_map(params) do
    result =
      SSH.add_key(Map.take(params, ["public_key", "label"]), actor: socket.assigns.current_user)

    socket = reset_form(socket)

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "SSH key added.") |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not add this key. Paste one supported public key; it must not belong to another account."
         )}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case SSH.remove_key(%{id: id}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "SSH key removed.") |> refresh()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not remove this key.") |> refresh()}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  defp refresh(socket) do
    case SSH.list_keys(%{}, actor: socket.assigns.current_user) do
      {:ok, keys} ->
        assign(socket, keys: keys)

      {:error, _} ->
        socket |> assign(keys: []) |> put_flash(:error, "SSH keys are temporarily unavailable.")
    end
  end

  defp reset_form(socket),
    do: assign(socket, form: to_form(%{"label" => "", "public_key" => ""}, as: :key))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{user: @current_user}} compute={true} active="ssh">
      <section class="stack">
        <UI.heading title="SSH keys" subtitle="Manage the keys you use to connect to your machines." />
        <.form for={@form} id="ssh-key-form" phx-submit="add" class="panel">
          <h2>Add a key</h2>
          <.input
            field={@form[:label]}
            label="Label (optional)"
            maxlength="128"
            placeholder="My laptop"
          />
          <.input
            field={@form[:public_key]}
            type="textarea"
            label="Public key"
            required
            maxlength="4096"
            rows="4"
            placeholder="ssh-ed25519 …"
            hint="Paste a public key from your .pub file. Never paste a private key."
          />
          <Layouts.action
            tone="primary"
            id="add-ssh-key"
            type="submit"
            phx-disable-with="Adding…"
          >
            Add SSH key
          </Layouts.action>
        </.form>
        <div class="stack">
          <h2>Your keys</h2>
          <p :if={@keys == []} id="ssh-keys-empty" class="empty-state">
            No SSH keys yet. You can always sign in here using email.
          </p>
          <article :for={key <- @keys} id={"ssh-key-#{key.id}"} class="panel">
            <header>
              <h3>{if key.label == "", do: "SSH key", else: key.label}</h3>
              <Layouts.action
                tone="danger"
                id={"remove-ssh-key-#{key.id}"}
                phx-click="remove"
                phx-value-id={key.id}
                data-confirm="Remove this key's SSH access? Already accepted machine operations will continue."
              >
                Remove
              </Layouts.action>
            </header>
            <p class="break"><code>{key.fingerprint}</code></p>
            <p class="muted">
              {key.algorithm} · Added {Calendar.strftime(key.inserted_at, "%Y-%m-%d")}
            </p>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
