defmodule MarshallWeb.Admin.OperationsLive do
  use MarshallWeb, :live_view

  alias Marshall.Administration.Operations

  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 30_000)
    {:ok, socket |> assign(snapshot: empty(), refreshed_at: nil) |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 30_000)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    case Operations.snapshot(socket.assigns.current_user) do
      {:ok, snapshot} ->
        assign(socket, snapshot: snapshot, refreshed_at: DateTime.utc_now())

      _ ->
        put_flash(
          socket,
          :error,
          dgettext("admin_operations", "Operational status is temporarily unavailable.")
        )
    end
  end

  defp empty,
    do: %{
      images: [],
      gateways: [],
      services: [],
      routes: [],
      publications: []
    }

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
      admin_active="operations"
    >
      <section id="admin-operations" class="stack">
        <UI.heading
          title={dgettext("admin_operations", "Platform status")}
          subtitle={
            dgettext(
              "admin_operations",
              "Read-only image, Audi ingress and Porsche gateway status. Secrets and certificate material are withheld."
            )
          }
        >
          <:actions>
            <span class="muted">{dgettext("admin_operations", "Updated")}
            <.timestamp at={@refreshed_at} zone={@time_zone} format={:datetime_seconds} />
            {dgettext("admin_operations", "· every 30 seconds")}</span>
          </:actions>
        </UI.heading>
        <.kv id="platform-summary">
          <:item title={dgettext("admin_operations", "Images")}>{tally(@snapshot.images)}</:item>
          <:item title={dgettext("admin_operations", "Porsche gateways")}>
            {tally(@snapshot.gateways)}
          </:item>
          <:item title={dgettext("admin_operations", "Audi services")}>
            {tally(@snapshot.services)}
          </:item>
          <:item title={dgettext("admin_operations", "Ingress routes")}>
            {length(@snapshot.routes)}
          </:item>
          <:item title={dgettext("admin_operations", "DNS publications")}>
            {length(@snapshot.publications)}
          </:item>
        </.kv>
        <UI.panel id="image-catalog" title={dgettext("admin_operations", "Image catalog")}>
          <p :if={@snapshot.images == []} class="muted">
            {dgettext("admin_operations", "No images in the catalog.")}
          </p>
          <div :if={@snapshot.images != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">{dgettext("admin_operations", "Image")}</th>
                  <th class="width-min">{dgettext("admin_operations", "Architecture")}</th>
                  <th class="width-min num">{dgettext("admin_operations", "Minimum RAM")}</th>
                  <th class="width-min num">{dgettext("admin_operations", "Minimum disk")}</th>
                  <th class="width-min">{dgettext("admin_operations", "Status")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={image <- @snapshot.images}>
                  <td class="break">{image.name}<br /><code class="muted">{image.id}</code></td>
                  <td>{image.architecture}</td>
                  <td class="num">{bytes(image.minimum_memory_bytes)}</td>
                  <td class="num">{bytes(image.minimum_disk_bytes)}</td>
                  <td><.enabled value={image.enabled} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="porsche-gateways" title={dgettext("admin_operations", "Porsche gateways")}>
          <p :if={@snapshot.gateways == []} class="muted">
            {dgettext("admin_operations", "No gateways enrolled.")}
          </p>
          <div :if={@snapshot.gateways != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">{dgettext("admin_operations", "Gateway")}</th>
                  <th class="width-min num">{dgettext("admin_operations", "Generation")}</th>
                  <th class="width-min">{dgettext("admin_operations", "Status")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={gateway <- @snapshot.gateways}>
                  <td class="break">{gateway.name}</td>
                  <td class="num">{gateway.generation}</td>
                  <td><.enabled value={gateway.enabled} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="audi-services" title={dgettext("admin_operations", "Audi services")}>
          <p :if={@snapshot.services == []} class="muted">
            {dgettext("admin_operations", "No Audi services enrolled.")}
          </p>
          <div :if={@snapshot.services != []} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">{dgettext("admin_operations", "Service")}</th>
                  <th class="width-min">{dgettext("admin_operations", "Role")}</th>
                  <th class="width-min num">{dgettext("admin_operations", "Generation")}</th>
                  <th class="width-min num">{dgettext("admin_operations", "Addresses")}</th>
                  <th class="width-min">{dgettext("admin_operations", "Status")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={service <- @snapshot.services}>
                  <td class="break">{service.name}</td>
                  <td>{service_role(service.role)}</td>
                  <td class="num">{service.generation}</td>
                  <td class="num">{length(service.addresses)}</td>
                  <td><.enabled value={service.enabled} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </UI.panel>
        <UI.panel id="ingress-routes" title={dgettext("admin_operations", "Ingress routes")}>
          <.status_list
            rows={@snapshot.routes}
            zone={@time_zone}
            empty={dgettext("admin_operations", "No ingress routes are published.")}
            fields={[
              {:vm_id, dgettext("admin_operations", "Machine")},
              {:revision, dgettext("admin_operations", "Revision")},
              {:certificate_expires_at, dgettext("admin_operations", "Certificate expires")},
              {:expires_at, dgettext("admin_operations", "Route expires")}
            ]}
          />
        </UI.panel>
        <UI.panel id="dns-publications" title={dgettext("admin_operations", "DNS publications")}>
          <.status_list
            rows={@snapshot.publications}
            zone={@time_zone}
            empty={dgettext("admin_operations", "No DNS publications are recorded.")}
            fields={[
              {:zone, dgettext("admin_operations", "Zone")},
              {:revision, dgettext("admin_operations", "Revision")}
            ]}
          />
        </UI.panel>
      </section>
    </Layouts.app>
    """
  end

  attr :rows, :list, required: true
  attr :fields, :list, required: true
  attr :empty, :string, required: true
  attr :zone, :string, required: true

  # @cc [owner:ghuntley,label:product] status-timestamp-provenance
  # Operational DateTime values MUST use the viewer's zone through the shared
  # timestamp component, retaining their stored UTC instant and hover title.
  @spec status_list(map()) :: Phoenix.LiveView.Rendered.t()
  defp status_list(assigns) do
    ~H"""
    <p :if={@rows == []} class="muted">{@empty}</p>
    <div :if={@rows != []} class="table-flow">
      <table>
        <thead>
          <tr>
            <th :for={{_field, title} <- @fields} class="width-min">{title}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td :for={{field, _title} <- @fields} class="break">
              <code>
                <%= case Map.get(row, field) do %>
                  <% %DateTime{} = instant -> %>
                    <.timestamp at={instant} zone={@zone} />
                  <% value -> %>
                    {format(value)}
                <% end %>
              </code>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :value, :boolean, required: true

  defp enabled(assigns) do
    ~H"""
    <span class="status-label" data-tone={if @value, do: "success", else: "muted"}>
      {if @value,
        do: dgettext("admin_operations", "Enabled"),
        else: dgettext("admin_operations", "Disabled")}
    </span>
    """
  end

  @spec tally([%{enabled: boolean()}]) :: String.t()
  defp tally([]), do: "0"

  defp tally(rows) do
    enabled = Enum.count(rows, & &1.enabled)

    dgettext("admin_operations", "%{count} · %{enabled} enabled",
      count: length(rows),
      enabled: enabled
    )
  end

  defp bytes(nil), do: dgettext("admin_operations", "unknown")
  defp bytes(value), do: "#{Float.round(value / 1_073_741_824, 1)} GiB"

  @spec format(String.t() | integer() | nil) :: String.t()
  defp format(nil), do: dgettext("admin_operations", "unknown")
  defp format(value), do: to_string(value)

  # @cc [owner:ghuntley,label:product] localized-audi-service-roles
  # Human role labels MUST translate the closed Audi service role enum while
  # service identifiers and enrollment values remain unchanged.
  @spec service_role(atom()) :: String.t()
  defp service_role(:dns), do: dgettext("admin_operations", "DNS")
  defp service_role(:gateway), do: dgettext("admin_operations", "Gateway")
  defp service_role(_), do: dgettext("admin_operations", "Unknown")
end
