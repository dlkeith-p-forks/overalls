defmodule MarshallWeb.Admin.AuditLive do
  use MarshallWeb, :live_view
  alias Marshall.Accounts
  alias MarshallWeb.Admin.AuditLabels
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         next_cursor: nil,
         unavailable?: false,
         lifecycle?: false,
         certificate?: false,
         uncertain_order: nil,
         filters: %{}
       )
       |> stream(:events, [])}

  @impl true
  def handle_params(%{"kind" => "lifecycle"} = params, _, socket) do
    keys = ~w(vm_id workflow_id host_id action since until before)
    filters = params |> Map.take(keys) |> Map.reject(fn {_, value} -> value == "" end)

    socket =
      assign(socket,
        lifecycle?: true,
        certificate?: false,
        uncertain_order: nil,
        filters: filters
      )

    case Marshall.Compute.lifecycle_history(Map.put(filters, "limit", 100),
           actor: socket.assigns.current_user
         ) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(next_cursor: page.next_cursor, unavailable?: false)
         |> stream(:events, page.items, reset: true)}

      _ ->
        {:noreply,
         socket
         |> assign(next_cursor: nil, unavailable?: true)
         |> stream(:events, [], reset: true)}
    end
  end

  def handle_params(%{"kind" => "certificates"}, _, socket) do
    {:noreply, certificate_history(socket)}
  end

  def handle_params(%{"kind" => "editor"}, _, socket) do
    case Marshall.Editor.audit(%{}, actor: socket.assigns.current_user) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(
           next_cursor: nil,
           unavailable?: false,
           lifecycle?: false,
           certificate?: false,
           uncertain_order: nil,
           filters: %{kind: "editor"}
         )
         |> stream(:events, page.items, reset: true)}

      _ ->
        {:noreply,
         socket
         |> assign(
           next_cursor: nil,
           unavailable?: true,
           lifecycle?: false,
           certificate?: false,
           uncertain_order: nil,
           filters: %{kind: "editor"}
         )
         |> stream(:events, [], reset: true)}
    end
  end

  def handle_params(params, _, socket) do
    before = params["before"]

    if is_nil(before) or OverallsProtocol.uuid?(before),
      do:
        {:noreply,
         refresh(
           assign(socket,
             lifecycle?: false,
             certificate?: false,
             uncertain_order: nil,
             filters: %{}
           ),
           before
         )},
      else: {:noreply, push_navigate(socket, to: ~p"/admin/audit")}
  end

  @impl true
  def handle_event("rotate-certificate", _, socket) do
    case Marshall.Ingress.rotate_fleet_certificate(%{}, actor: socket.assigns.current_user) do
      {:ok, %{generation: generation}} ->
        {:noreply,
         socket
         |> certificate_history()
         |> put_flash(
           :info,
           dgettext("admin_audit", "Wildcard rotation requested for generation %{generation}.",
             generation: generation
           )
         )}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("admin_audit", "Wildcard rotation could not be requested.")
         )}
    end
  end

  defp certificate_history(socket) do
    case Marshall.Ingress.certificate_audit(%{}, actor: socket.assigns.current_user) do
      {:ok, page} ->
        socket
        |> assign(
          next_cursor: nil,
          unavailable?: false,
          lifecycle?: false,
          certificate?: true,
          uncertain_order: page.uncertain_order,
          filters: %{}
        )
        |> stream(:events, page.items, reset: true)

      _ ->
        socket
        |> assign(
          next_cursor: nil,
          unavailable?: true,
          lifecycle?: false,
          certificate?: true,
          uncertain_order: nil,
          filters: %{}
        )
        |> stream(:events, [], reset: true)
    end
  end

  defp refresh(socket, before) do
    case Accounts.admin_events(%{before: before, limit: 100}, actor: socket.assigns.current_user) do
      {:ok, page} ->
        socket
        |> assign(next_cursor: page.next_cursor, unavailable?: false)
        |> stream(:events, page.items, reset: true)

      _ ->
        socket |> assign(next_cursor: nil, unavailable?: true) |> stream(:events, [], reset: true)
    end
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
      active="admin"
      admin_active="audit"
    >
      <section id="admin-audit" class="stack">
        <UI.heading
          title={dgettext("admin_audit", "Audit")}
          subtitle={
            dgettext(
              "admin_audit",
              "Redacted authority changes, lifecycle requests, certificate generations and editor access. Payloads, credentials and terminal bytes are excluded."
            )
          }
        />
        <nav class="machine-tabs" aria-label={dgettext("admin_audit", "Audit kinds")}>
          <.link
            patch={~p"/admin/audit"}
            aria-current={
              (!@lifecycle? and !@certificate? and Map.get(@filters, :kind) != "editor") && "page"
            }
          >
            {dgettext("admin_audit", "Administrator actions")}
          </.link>
          <.link patch={~p"/admin/audit?kind=lifecycle"} aria-current={@lifecycle? && "page"}>{dgettext(
            "admin_audit",
            "VM lifecycle"
          )}</.link>
          <.link patch={~p"/admin/audit?kind=certificates"} aria-current={@certificate? && "page"}>{dgettext(
            "admin_audit",
            "Certificates"
          )}</.link>
          <.link
            patch={~p"/admin/audit?kind=editor"}
            aria-current={Map.get(@filters, :kind) == "editor" && "page"}
          >{dgettext("admin_audit", "VS Code access")}</.link>
        </nav>
        <form :if={@lifecycle?} action={~p"/admin/audit"} method="get" class="panel stack">
          <h2>{dgettext("admin_audit", "Filter lifecycle history")}</h2>
          <input type="hidden" name="kind" value="lifecycle" />
          <div class="grid">
            <div
              :for={
                {key, label} <- [
                  {"vm_id", dgettext("admin_audit", "VM ID")},
                  {"workflow_id", dgettext("admin_audit", "Workflow ID")},
                  {"host_id", dgettext("admin_audit", "Host ID")}
                ]
              }
              class="field"
            >
              <label>
                <span class="field-label">{label}</span>
                <input name={key} value={@filters[key]} />
              </label>
            </div>
          </div>
          <div class="grid">
            <div
              :for={
                {key, label} <- [
                  {"action", dgettext("admin_audit", "Action")},
                  {"since", dgettext("admin_audit", "Since (ISO 8601)")},
                  {"until", dgettext("admin_audit", "Until (ISO 8601)")}
                ]
              }
              class="field"
            >
              <label>
                <span class="field-label">{label}</span>
                <input name={key} value={@filters[key]} />
              </label>
            </div>
          </div>
          <div class="row actions">
            <button type="submit" class="console-button primary">{dgettext(
              "admin_audit",
              "Filter lifecycle history"
            )}</button>
          </div>
        </form>
        <p :if={@lifecycle?} class="muted">
          {dgettext(
            "admin_audit",
            "Human requests and system recovery transitions. History is retained for 90 days."
          )}
        </p>
        <p :if={@certificate?} class="muted">
          {dgettext(
            "admin_audit",
            "Recent fleet wildcard generations and gateway installations. Private keys and ACME proofs are excluded."
          )}
        </p>
        <p
          :if={@certificate? and @uncertain_order}
          id="uncertain-fleet-order"
          role="status"
          class="panel dashed"
        >
          {dgettext(
            "admin_audit",
            "Generation %{generation} has an uncertain ACME order response. The generation can be failed after",
            generation: @uncertain_order.generation
          )}
          <.timestamp at={@uncertain_order.retry_after} zone={@time_zone} format={:datetime_seconds} />{dgettext(
            "admin_audit",
            "; the next due check can then request a new generation."
          )}
        </p>
        <div :if={@admin_authorized and @certificate?} class="row actions">
          <button
            id="rotate-fleet-certificate"
            type="button"
            phx-click="rotate-certificate"
            data-confirm={
              dgettext("admin_audit", "Request a new wildcard certificate for every Audi gateway?")
            }
            class="console-button"
          >{dgettext("admin_audit", "Request wildcard rotation")}</button>
        </div>
        <p :if={@unavailable?} role="alert" class="error">
          {dgettext("admin_audit", "Audit history is unavailable.")}
        </p>
        <div id="audit-events" class="table-flow">
          <table>
            <thead>
              <tr>
                <th class="width-min">{dgettext("admin_audit", "When")}</th>
                <th class="width-min">{dgettext("admin_audit", "Action")}</th>
                <th class="width-min">{dgettext("admin_audit", "Actor")}</th>
                <th class="width-auto">{dgettext("admin_audit", "Target")}</th>
              </tr>
            </thead>
            <tbody id="audit-event-rows" phx-update="stream">
              <tr :for={{dom_id, event} <- @streams.events} id={dom_id}>
                <td class="nowrap">
                  <.timestamp at={event.inserted_at} zone={@time_zone} format={:datetime_seconds} />
                </td>
                <td class="nowrap">
                  {AuditLabels.action(if @lifecycle?, do: event.action, else: event.kind)}
                  <br /><code>{if @lifecycle?, do: event.action, else: event.kind}</code>
                </td>
                <td class="nowrap">
                  <code>{cond do
                    @lifecycle? -> event.actor_id || event.actor_kind
                    @certificate? -> event.host_id || event.actor_id || event.actor_kind || "system"
                    true -> event.actor_id
                  end}</code>
                </td>
                <td class="break">
                  <span :if={@lifecycle?}>
                    <code>{event.resource_type} {event.resource_id}</code><br />
                    {AuditLabels.state(event.previous_state || "created")} → {AuditLabels.state(
                      event.next_state
                    )}
                    <br /><code>{event.previous_state || "—"} → {event.next_state || "—"}</code>
                  </span>
                  <span :if={@certificate? and event.kind == :account}>{dgettext(
                    "admin_audit",
                    "ACME account: %{status}",
                    status: AuditLabels.action(event.status)
                  )}<br /><code>{event.status}</code></span>
                  <span :if={@certificate? and event.kind != :account}>{dgettext(
                    "admin_audit",
                    "Generation %{generation}: %{status}",
                    generation: event.generation,
                    status: AuditLabels.action(event.status)
                  )}<br /><code>{event.status}</code><br /><code>{event.fingerprint ||
                    dgettext("admin_audit", "Pending")}</code></span>
                  <span :if={!@lifecycle? and !@certificate?}><code>{event.target_id}</code></span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@next_cursor}>
          <.link patch={
            ~p"/admin/audit?#{Map.merge(@filters, if(@lifecycle?, do: %{kind: "lifecycle", before: @next_cursor}, else: %{before: @next_cursor}))}"
          }>{dgettext("admin_audit", "Older events →")}</.link>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
