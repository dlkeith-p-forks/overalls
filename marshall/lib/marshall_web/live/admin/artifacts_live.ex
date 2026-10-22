defmodule MarshallWeb.Admin.ArtifactsLive do
  @moduledoc """
  Elevated-administrator artifact moderation: metadata only, never content.
  Deletion requires a closed moderation reason and Cedar `artifact_admin_delete`.
  """
  use MarshallWeb, :live_view
  import Ecto.Query

  on_mount({MarshallWeb.AuthenticationPrivacy, :default})
  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})
  on_mount({MarshallWeb.LiveAdminAuth, :required})

  @reasons [:abuse, :legal, :security, :owner_request, :other]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(query: "", unavailable?: false) |> refresh()}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket),
    do: {:noreply, socket |> assign(query: String.slice(String.trim(query), 0, 256)) |> refresh()}

  def handle_event("delete", %{"artifact_id" => id, "reason" => reason}, socket)
      when reason in ["abuse", "legal", "security", "owner_request", "other"] do
    case Marshall.Artifacts.Library.admin_delete(
           socket.assigns.current_user,
           id,
           String.to_existing_atom(reason)
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("artifacts", "Artifact deleted for moderation."))
         |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("artifacts", "The artifact could not be deleted."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Metadata only: no page, file or storage content is read here.
  defp refresh(socket) do
    pattern =
      if socket.assigns.query == "",
        do: nil,
        else: "%" <> Marshall.Threads.Coordinator.escape_like(socket.assigns.query) <> "%"

    rows =
      from(a in "artifacts",
        where: a.state == "active",
        order_by: [desc: a.updated_at],
        limit: 100,
        select: %{
          id: type(a.id, :binary_id),
          owner_id: type(a.owner_id, :binary_id),
          title: a.title,
          bytes: a.total_bytes,
          versions: a.current_version,
          state: a.state
        }
      )
      |> then(fn query ->
        if pattern,
          do: from(a in query, where: fragment("? ILIKE ? ESCAPE '\\'", a.title, ^pattern)),
          else: query
      end)
      |> Marshall.Repo.all()

    assign(socket, rows: rows, unavailable?: false)
  rescue
    _ -> assign(socket, rows: [], unavailable?: true)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :reasons, @reasons)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="admin"
      admin_active="artifacts"
    >
      <section id="admin-artifacts" class="stack">
        <h1>{dgettext("artifacts", "Artifact moderation")}</h1>
        <p class="muted">
          {dgettext(
            "artifacts",
            "Administrators can delete artifacts for a recorded reason. Content is never shown here."
          )}
        </p>
        <form id="admin-artifacts-search" phx-submit="search" role="search">
          <label for="admin-artifacts-query">{dgettext("artifacts", "Search titles")}</label>
          <input id="admin-artifacts-query" name="q" type="search" value={@query} maxlength="256" />
        </form>
        <p :if={@unavailable?}>{dgettext("artifacts", "Artifacts are unavailable.")}</p>
        <table id="admin-artifacts-list">
          <thead>
            <tr>
              <th>{dgettext("artifacts", "Title")}</th>
              <th class="width-min">{dgettext("artifacts", "Owner")}</th>
              <th class="width-min">{dgettext("artifacts", "Bytes")}</th>
              <th class="width-min">{dgettext("artifacts", "Versions")}</th>
              <th class="width-min">{dgettext("artifacts", "Delete")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"admin-artifact-#{row.id}"}>
              <td>{row.title}</td>
              <td><code>{row.owner_id}</code></td>
              <td>{row.bytes}</td>
              <td>{row.versions}</td>
              <td>
                <form phx-submit="delete" class="row">
                  <input type="hidden" name="artifact_id" value={row.id} />
                  <select name="reason" aria-label={dgettext("artifacts", "Moderation reason")}>
                    <option :for={reason <- @reasons} value={reason}>{reason_label(reason)}</option>
                  </select>
                  <button
                    type="submit"
                    data-confirm={dgettext("artifacts", "Delete this artifact and every version?")}
                  >
                    {dgettext("artifacts", "Delete")}
                  </button>
                </form>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end

  defp reason_label(:abuse), do: dgettext("artifacts", "Abuse")
  defp reason_label(:legal), do: dgettext("artifacts", "Legal")
  defp reason_label(:security), do: dgettext("artifacts", "Security")
  defp reason_label(:owner_request), do: dgettext("artifacts", "Owner request")
  defp reason_label(:other), do: dgettext("artifacts", "Other")
end
