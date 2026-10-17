defmodule MarshallWeb.IntegrationsLive do
  use MarshallWeb, :live_view
  alias Marshall.Galileo
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket) do
    {:ok, socket |> assign(integrations: []) |> reset_form() |> refresh()}
  end

  # @cc [owner:ghuntley,label:security] browser-integration-secret-write-only
  # Secret form fields MUST be cleared after every attempt and MUST never be
  # reflected in diagnostics, listings or receipts. Stored values display only
  # as their kind; the write-only boundary lives in the domain. Each attempt
  # MUST replace password inputs so browser-local values cannot survive a patch
  # whose server-side form values were already empty.
  @impl true
  def handle_event("add", %{"integration" => params}, socket) when is_map(params) do
    user = socket.assigns.current_user

    result =
      Galileo.configure_integration(
        %{
          name: params["name"],
          target: blank_to_nil(params["target"]),
          strip_prefix: blank_to_nil(params["strip_prefix"]),
          headers: header_params(params),
          peer: Map.get(params, "peer") == "true",
          peer_vm_id: blank_to_nil(params["peer_vm_id"]),
          team_id: blank_to_nil(params["team_id"]),
          idempotency_key: "web:" <> Ash.UUID.generate()
        },
        actor: user
      )

    socket = reset_form(socket)

    case result do
      {:ok, integration} ->
        {:noreply,
         socket |> put_flash(:info, "Integration #{integration.name} saved.") |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not save this integration. Check the name, HTTPS target and header values."
         )}
    end
  end

  def handle_event("remove", %{"name" => name}, socket) do
    case Galileo.remove_integration(%{name: name}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Integration removed.") |> refresh()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not remove this integration.") |> refresh()}
    end
  end

  def handle_event("attach", %{"name" => name, "attachment" => %{"vm_id" => vm_id}}, socket) do
    case Galileo.attach_integration(%{name: name, vm_id: vm_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Machine attached.") |> refresh()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not attach that machine.") |> refresh()}
    end
  end

  def handle_event("detach", %{"name" => name, "vm-id" => vm_id}, socket) do
    case Galileo.detach_integration(%{name: name, vm_id: vm_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Machine detached.") |> refresh()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not detach that machine.") |> refresh()}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  defp refresh(socket) do
    case Galileo.list_integrations(%{}, actor: socket.assigns.current_user) do
      {:ok, integrations} ->
        assign(socket, integrations: integrations)

      {:error, _} ->
        socket
        |> assign(integrations: [])
        |> put_flash(:error, "Integrations are temporarily unavailable.")
    end
  end

  defp reset_form(socket) do
    assign(
      socket,
      form_generation: Map.get(socket.assigns, :form_generation, 0) + 1,
      form:
        to_form(
          %{
            "name" => "",
            "target" => "",
            "strip_prefix" => "",
            "bearer" => "",
            "basic" => "",
            "header_name" => "",
            "header_value" => "",
            "peer" => "false",
            "peer_vm_id" => "",
            "team_id" => ""
          },
          as: :integration
        )
    )
  end

  defp header_params(params) do
    static =
      case {blank_to_nil(params["header_name"]), blank_to_nil(params["header_value"])} do
        {nil, nil} -> []
        {name, value} -> [%{kind: :static, name: name, value: value}]
      end

    bearer =
      case blank_to_nil(params["bearer"]) do
        nil -> []
        token -> [%{kind: :bearer, name: "authorization", value: token}]
      end

    basic =
      case blank_to_nil(params["basic"]) do
        nil -> []
        credentials -> [%{kind: :basic, name: "authorization", value: credentials}]
      end

    if params["bearer"] != "" && params["basic"] != "",
      do: [%{kind: :static, name: "invalid", value: "conflicting credentials"}],
      else: static ++ bearer ++ basic
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      compute={true}
      active="integrations"
    >
      <section id="integrations-page" class="stack">
        <UI.heading
          title="Integrations"
          subtitle="Named endpoints your machines reach at https://NAME.integration.internal. Credentials are injected at the edge and are never readable from a machine."
        />
        <p :if={@integrations == []} class="empty-state">
          No integrations yet. Add one below to give your machines a named connection to an API
          or to another machine.
        </p>
        <div id="integrations" class="stack">
          <article
            :for={integration <- @integrations}
            id={"integration-#{integration.id}"}
            class="panel"
          >
            <header>
              <h2 class="ident break"><code>{integration.name}.integration.internal</code></h2>
              <div class="row">
                <span class="status-label">{if integration.team_id, do: "team", else: "personal"}</span>
                <button
                  id={"remove-integration-#{integration.id}"}
                  phx-click="remove"
                  phx-value-name={integration.name}
                  data-confirm="Remove this integration?"
                  class="console-button danger"
                >
                  Remove
                </button>
              </div>
            </header>
            <div class="panel-body">
              <.kv>
                <:item :if={integration.target} title="Target">
                  <span class="break">{integration.target}</span>
                </:item>
                <:item :if={!integration.target} title="Peer machine">
                  <code class="break">{integration.peer_vm_id}</code>
                </:item>
                <:item title="Owner">
                  {if integration.team_id,
                    do: "Team " <> integration.team_id,
                    else: "Personal integration"}
                </:item>
                <:item :if={integration.strip_prefix} title="Strips prefix">
                  <code>{integration.strip_prefix}</code>
                </:item>
              </.kv>
              <h3>Injected credentials</h3>
              <div id={"integration-headers-#{integration.id}"}>
                <p :if={integration.headers == []} class="muted">No injected headers.</p>
                <.kv :if={integration.headers != []}>
                  <:item :for={header <- integration.headers} title={header.name}>
                    <span class="muted">**** (write-only)</span>
                  </:item>
                </.kv>
              </div>
              <h3>Machines with access</h3>
              <div id={"integration-attachments-#{integration.id}"}>
                <p :if={integration.attachments == []} class="muted">
                  {if integration.team_id,
                    do: "No explicit attachments. Current team members' machines have access.",
                    else: "No machines have access. Attach a machine to use this integration."}
                </p>
                <div :if={integration.attachments != []} class="table-flow">
                  <table>
                    <thead>
                      <tr>
                        <th class="width-auto">Machine</th>
                        <th class="width-min"><span class="sr-only">Actions</span></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={attachment <- integration.attachments}
                        id={"integration-attachment-#{attachment.id}"}
                      >
                        <td class="break"><code>{attachment.vm_id}</code></td>
                        <td>
                          <button
                            phx-click="detach"
                            phx-value-name={integration.name}
                            phx-value-vm-id={attachment.vm_id}
                            class="console-button compact"
                          >
                            Detach
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <.form
                for={to_form(%{"vm_id" => ""}, as: :attachment)}
                id={"attach-form-#{integration.id}"}
                phx-submit="attach"
                class="field-row"
              >
                <input type="hidden" name="name" value={integration.name} />
                <.input
                  id={"attachment-vm-#{integration.id}"}
                  name="attachment[vm_id]"
                  value=""
                  label="Attach a machine by ID"
                  placeholder="Machine UUID"
                />
                <button class="console-button">Attach</button>
              </.form>
            </div>
          </article>
        </div>
        <.form for={@form} id="integration-form" phx-submit="add" class="panel stack">
          <h2>Add an integration</h2>
          <p class="muted">
            Name the endpoint and point it at an HTTPS API, or mark it as a peer connection to
            another machine. Secrets are write-only: they are stored for injection and never
            shown again.
          </p>
          <div class="grid">
            <.input field={@form[:name]} label="Name" placeholder="example-integration" />
            <.input field={@form[:target]} label="HTTPS target" placeholder="https://api.example.com" />
          </div>
          <h3>Credentials</h3>
          <div class="grid">
            <.input
              id={"integration-bearer-#{@form_generation}"}
              field={@form[:bearer]}
              label="Bearer token"
              type="password"
            />
            <.input
              id={"integration-basic-#{@form_generation}"}
              field={@form[:basic]}
              label="Basic user:pass"
              type="password"
            />
          </div>
          <div class="grid">
            <.input
              field={@form[:header_name]}
              label="Static header name"
              placeholder="x-api-token"
            />
            <.input
              id={"integration-header-value-#{@form_generation}"}
              field={@form[:header_value]}
              label="Static header value"
              type="password"
            />
          </div>
          <details class="integration-options">
            <summary>Routing, team ownership and peer connections</summary>
            <div class="stack">
              <div class="grid">
                <.input
                  field={@form[:strip_prefix]}
                  label="Strip prefix"
                  placeholder="/api/v3"
                />
                <.input
                  field={@form[:team_id]}
                  label="Team ID"
                  placeholder="Team-owned integration"
                />
              </div>
              <div class="grid">
                <.input field={@form[:peer]} label="Peer integration" type="checkbox" />
                <.input
                  field={@form[:peer_vm_id]}
                  label="Peer machine ID"
                  placeholder="Required for peer integrations"
                />
              </div>
            </div>
          </details>
          <div class="row actions">
            <button type="submit" class="console-button primary">Save integration</button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
