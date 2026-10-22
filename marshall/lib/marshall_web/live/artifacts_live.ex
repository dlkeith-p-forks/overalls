defmodule MarshallWeb.ArtifactsLive do
  @moduledoc "Agent-published pages: list, sandboxed viewer, versions and Cedar sharing."
  use MarshallWeb, :live_view

  alias Marshall.Artifacts.{Authorization, Library, Sharing, Storage, Tickets}

  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})

  @type socket :: Phoenix.LiveView.Socket.t()

  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("artifacts", "Artifacts"),
       query: "",
       items: [],
       next_cursor: nil,
       artifact: nil,
       version: nil,
       versions: [],
       files: [],
       frame_src: nil,
       role: nil,
       can_share: false,
       can_delete: false,
       grants: [],
       share_form: to_form(%{"email" => "", "role" => "viewer"}, as: :access),
       share_request_key: Ash.UUID.generate()
     )}
  end

  @impl true
  @spec handle_params(map(), String.t(), socket()) :: {:noreply, socket()}
  def handle_params(params, _uri, %{assigns: %{live_action: :index}} = socket) do
    query = params |> Map.get("q", "") |> String.trim() |> String.slice(0, 256)
    actor = socket.assigns.current_user

    page =
      Library.list(actor, %{
        query: if(query == "", do: nil, else: query),
        after: params["after"],
        limit: 50
      })

    {:noreply, assign(socket, query: query, items: page.items, next_cursor: page.next_cursor)}
  end

  def handle_params(%{"id" => id} = params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, artifact} <- Library.fetch(id, actor),
         {:ok, version} <- selected_version(artifact, socket.assigns.live_action, params) do
      {:noreply, socket |> load(artifact, version)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("artifacts", "That artifact is unavailable."))
         |> push_navigate(to: ~p"/artifacts")}
    end
  end

  @spec selected_version(Marshall.Artifacts.Artifact.t(), atom(), map()) ::
          {:ok, Marshall.Artifacts.Version.t() | nil} | {:error, :not_found}
  defp selected_version(artifact, :version, %{"number" => number}) do
    case Integer.parse(number) do
      {value, ""} when value >= 1 -> Library.version(artifact, value)
      _ -> {:error, :not_found}
    end
  end

  defp selected_version(%{current_version: 0}, _action, _params), do: {:ok, nil}
  defp selected_version(artifact, _action, _params), do: Library.version(artifact, nil)

  @spec load(socket(), Marshall.Artifacts.Artifact.t(), Marshall.Artifacts.Version.t() | nil) ::
          socket()
  defp load(socket, artifact, version) do
    actor = socket.assigns.current_user
    can_share = Authorization.allowed?(artifact, actor, :share)

    assign(socket,
      page_title: artifact.title,
      artifact: artifact,
      version: version,
      versions:
        if(socket.assigns.live_action == :versions, do: Library.versions(artifact), else: []),
      files: if(version, do: Library.files(version), else: []),
      frame_src: frame_src(actor, artifact, version, socket.assigns.live_action),
      role: Authorization.role(artifact, actor),
      can_share: can_share,
      can_delete: Authorization.allowed?(artifact, actor, :delete),
      grants:
        if(can_share and socket.assigns.live_action == :sharing,
          do: Library.labelled_grants(artifact),
          else: []
        )
    )
  end

  # A fresh five-minute ticket per render of the viewer; never in a query string.
  @spec frame_src(
          Marshall.Accounts.User.t(),
          Marshall.Artifacts.Artifact.t(),
          Marshall.Artifacts.Version.t() | nil,
          atom()
        ) :: String.t() | nil
  defp frame_src(_actor, _artifact, nil, _action), do: nil

  defp frame_src(actor, artifact, version, action) when action in [:show, :version] do
    with host when is_binary(host) <- MarshallWeb.ArtifactContentEndpoint.config().host,
         {:ok, ticket} <- Tickets.issue(actor, artifact, version, host) do
      "https://" <> host <> "/v/" <> ticket <> "/"
    else
      _ -> nil
    end
  end

  defp frame_src(_actor, _artifact, _version, _action), do: nil

  @impl true
  @spec handle_event(String.t(), map(), socket()) ::
          {:noreply, socket()} | {:reply, map(), socket()}
  def handle_event("search", %{"q" => query}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/artifacts?#{%{q: query}}")}

  def handle_event("delete", _params, %{assigns: %{artifact: artifact}} = socket) do
    case Library.delete(socket.assigns.current_user, artifact.id, :web) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("artifacts", "Artifact deleted."))
         |> push_navigate(to: ~p"/artifacts")}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("artifacts", "The artifact could not be deleted."))}
    end
  end

  def handle_event("share", %{"access" => %{"email" => email, "role" => role}}, socket)
      when role in ["owner", "writer", "viewer", "revoked"] do
    artifact = socket.assigns.artifact

    case Sharing.set_access(
           socket.assigns.current_user,
           artifact.id,
           {:email, String.trim(email)},
           String.to_existing_atom(role),
           socket.assigns.share_request_key
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           share_request_key: Ash.UUID.generate(),
           grants: Library.labelled_grants(artifact)
         )
         |> put_flash(:info, dgettext("artifacts", "Access updated."))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(share_request_key: Ash.UUID.generate())
         |> put_flash(:error, dgettext("artifacts", "Access could not be changed."))}
    end
  end

  def handle_event("revoke", %{"user" => user_id}, socket) do
    artifact = socket.assigns.artifact

    email =
      case Marshall.Accounts.Security.current(user_id) do
        %{email: email} -> to_string(email)
        _ -> nil
      end

    result =
      email &&
        Sharing.set_access(
          socket.assigns.current_user,
          artifact.id,
          {:email, email},
          :revoked,
          Ash.UUID.generate()
        )

    case result do
      {:ok, _} ->
        {:noreply, assign(socket, grants: Library.labelled_grants(artifact))}

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("artifacts", "Access could not be changed."))}
    end
  end

  # Storage requests from the sandboxed frame, already schema-checked in the
  # browser and validated again here; Cedar, caps and audit apply in Storage.
  def handle_event("storage", %{"op" => op, "namespace" => namespace} = request, socket)
      when op in ["get", "set", "delete", "list"] and namespace in ["personal", "shared"] do
    actor = socket.assigns.current_user
    id = socket.assigns.artifact && socket.assigns.artifact.id
    ns = String.to_existing_atom(namespace)

    reply =
      case {id, op} do
        {nil, _} -> {:error, :not_found}
        {id, "get"} -> Storage.get(actor, id, ns, request["key"])
        {id, "set"} -> Storage.put(actor, id, ns, request["key"], request["value"])
        {id, "delete"} -> Storage.delete(actor, id, ns, request["key"])
        {id, "list"} -> Storage.list(actor, id, ns, request["prefix"])
      end

    {:reply, storage_reply(op, reply), socket}
  end

  def handle_event("storage", _params, socket),
    do: {:reply, %{ok: false, error: "invalid_request"}, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp storage_reply("list", {:ok, keys}), do: %{ok: true, op: "list", keys: keys}
  defp storage_reply(op, {:ok, value}), do: %{ok: true, op: op, value: value}
  defp storage_reply(op, :ok), do: %{ok: true, op: op, value: nil}

  defp storage_reply(op, {:error, reason}),
    do: %{ok: false, op: op, error: Atom.to_string(reason)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="artifacts"
    >
      <section :if={@live_action == :index} id="artifacts" class="stack">
        <header class="row">
          <h1>{dgettext("artifacts", "Artifacts")}</h1>
        </header>
        <p class="muted">
          {dgettext(
            "artifacts",
            "Pages your agents publish from threads. Each publish creates a new version; only people you share with can open them."
          )}
        </p>
        <form id="artifacts-search" phx-submit="search" role="search">
          <label for="artifacts-query">{dgettext("artifacts", "Search titles")}</label>
          <input id="artifacts-query" name="q" type="search" value={@query} maxlength="256" />
        </form>
        <p :if={@items == []} id="artifacts-empty">{dgettext("artifacts", "No artifacts yet.")}</p>
        <table :if={@items != []} id="artifacts-list">
          <thead>
            <tr>
              <th>{dgettext("artifacts", "Title")}</th>
              <th class="width-min">{dgettext("artifacts", "Version")}</th>
              <th class="width-min">{dgettext("artifacts", "Updated")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={artifact <- @items} id={"artifact-#{artifact.id}"}>
              <td><.link navigate={~p"/artifacts/#{artifact.id}"}>{artifact.title}</.link></td>
              <td>{artifact.current_version}</td>
              <td>
                <time datetime={DateTime.to_iso8601(artifact.updated_at)}>{Calendar.strftime(
                  artifact.updated_at,
                  "%Y-%m-%d %H:%M"
                )}</time>
              </td>
            </tr>
          </tbody>
        </table>
        <.link
          :if={@next_cursor}
          id="artifacts-next"
          patch={~p"/artifacts?#{%{q: @query, after: @next_cursor}}"}
        >
          {dgettext("artifacts", "Older artifacts")}
        </.link>
      </section>

      <section :if={@artifact && @live_action != :index} id="artifact" class="stack">
        <header class="row">
          <h1>{@artifact.title}</h1>
          <span id="artifact-role">[{role_label(@role)}]</span>
        </header>
        <nav class="row" aria-label={dgettext("artifacts", "Artifact sections")}>
          <.link
            navigate={~p"/artifacts/#{@artifact.id}"}
            aria-current={@live_action == :show && "page"}
          >
            {dgettext("artifacts", "View")}
          </.link>
          <.link
            navigate={~p"/artifacts/#{@artifact.id}/versions"}
            aria-current={@live_action == :versions && "page"}
          >
            {dgettext("artifacts", "Versions")}
          </.link>
          <.link
            :if={@can_share}
            navigate={~p"/artifacts/#{@artifact.id}/sharing"}
            aria-current={@live_action == :sharing && "page"}
          >
            {dgettext("artifacts", "Sharing")}
          </.link>
          <button
            :if={@can_delete}
            id="artifact-delete"
            phx-click="delete"
            data-confirm={dgettext("artifacts", "Delete this artifact and every version?")}
          >
            {dgettext("artifacts", "Delete")}
          </button>
        </nav>

        <div
          :if={@live_action in [:show, :version]}
          id="artifact-viewer"
          phx-hook="ArtifactFrame"
          class="stack"
        >
          <p :if={@version}>
            {dgettext("artifacts", "Version %{number} of %{current}",
              number: @version.number,
              current: @artifact.current_version
            )}
          </p>
          <iframe
            :if={@frame_src}
            id="artifact-frame"
            data-artifact-frame
            src={@frame_src}
            sandbox="allow-scripts"
            referrerpolicy="no-referrer"
            credentialless
            allow=""
            title={@artifact.title}
          ></iframe>
          <p :if={is_nil(@frame_src)} id="artifact-viewer-unavailable">
            {dgettext("artifacts", "The viewer is unavailable on this deployment.")}
          </p>
          <details :if={@files != []}>
            <summary>{dgettext("artifacts", "Files")}</summary>
            <ul>
              <li :for={file <- @files}>{file.path} ({file.bytes} B)</li>
            </ul>
          </details>
        </div>

        <table :if={@live_action == :versions} id="artifact-versions">
          <thead>
            <tr>
              <th class="width-min">{dgettext("artifacts", "Version")}</th>
              <th>{dgettext("artifacts", "Title")}</th>
              <th class="width-min">{dgettext("artifacts", "Published")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={version <- @versions} id={"artifact-version-#{version.number}"}>
              <td>
                <.link navigate={~p"/artifacts/#{@artifact.id}/versions/#{version.number}"}>{version.number}</.link>
              </td>
              <td>{version.title}</td>
              <td>
                <time datetime={DateTime.to_iso8601(version.inserted_at)}>{Calendar.strftime(
                  version.inserted_at,
                  "%Y-%m-%d %H:%M"
                )}</time>
              </td>
            </tr>
          </tbody>
        </table>

        <section :if={@live_action == :sharing and @can_share} id="artifact-sharing" class="stack">
          <h2>{dgettext("artifacts", "People with access")}</h2>
          <ul id="artifact-grants">
            <li :for={{grant, label} <- @grants} id={"artifact-grant-#{grant.id}"}>
              {label} [{role_label(grant.role)}]
              <button :if={grant.user_id} phx-click="revoke" phx-value-user={grant.user_id}>
                {dgettext("artifacts", "Remove")}
              </button>
            </li>
          </ul>
          <.form for={@share_form} id="artifact-share-form" phx-submit="share" class="grid">
            <label for="artifact-share-email">{dgettext("artifacts", "Email")}</label>
            <input
              id="artifact-share-email"
              name="access[email]"
              type="email"
              required
              maxlength="320"
            />
            <label for="artifact-share-role">{dgettext("artifacts", "Role")}</label>
            <select id="artifact-share-role" name="access[role]">
              <option value="viewer">{role_label(:viewer)}</option>
              <option value="writer">{role_label(:writer)}</option>
              <option value="owner">{role_label(:owner)}</option>
            </select>
            <button type="submit">{dgettext("artifacts", "Share")}</button>
          </.form>
        </section>
      </section>
    </Layouts.app>
    """
  end

  @spec role_label(atom() | nil) :: String.t()
  defp role_label(:owner), do: dgettext("artifacts", "owner")
  defp role_label(:writer), do: dgettext("artifacts", "writer")
  defp role_label(:viewer), do: dgettext("artifacts", "viewer")
  defp role_label(_), do: dgettext("artifacts", "no access")
end
