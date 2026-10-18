defmodule MarshallWeb.GitLive do
  use MarshallWeb, :live_view
  alias Marshall.Enrico.Catalog
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         repos: [],
         repo: nil,
         content: "",
         entries: [],
         refs: [],
         commits: [],
         ref: "HEAD",
         path: "",
         view: "tree",
         query: "",
         unavailable?: false
       )}

  @impl true
  def handle_params(%{"owner" => owner, "repo" => name} = params, _, socket) do
    repo = Catalog.get(socket.assigns.current_user, owner, name)
    ref = Map.get(params, "ref", if(repo, do: repo.head || "HEAD", else: "HEAD"))
    path = Map.get(params, "path", "")
    view = Map.get(params, "view", "tree")
    query = Map.get(params, "q", "")
    socket = assign(socket, repo: repo, ref: ref, path: path, view: view, query: query)

    if repo && view in ["tree", "blob", "history", "diff", "blame", "refs", "search"] do
      operation = if view == "search", do: "search", else: view

      arguments =
        if view == "search",
          do: %{ref: ref, q: query, kind: Map.get(params, "kind", "content")},
          else: %{ref: ref, path: path}

      case Catalog.inspect(socket.assigns.current_user, repo, operation, arguments) do
        {:ok, %{"data_base64" => encoded}} ->
          with {:ok, bytes} <- Base.decode64(encoded) do
            entries = if view == "tree", do: parse_tree(bytes), else: []
            refs = if view == "refs", do: parse_refs(bytes), else: []
            commits = if view == "history", do: parse_history(bytes), else: []

            {:noreply,
             assign(socket,
               entries: entries,
               refs: refs,
               commits: commits,
               content: display(bytes),
               unavailable?: false
             )}
          else
            _ -> {:noreply, assign(socket, unavailable?: true)}
          end

        {:ok, bytes} when is_binary(bytes) ->
          {:noreply,
           assign(socket,
             content: display(bytes),
             entries: [],
             refs: [],
             commits: [],
             unavailable?: false
           )}

        _ ->
          {:noreply,
           assign(socket, unavailable?: true, entries: [], refs: [], commits: [], content: "")}
      end
    else
      {:noreply,
       assign(socket, unavailable?: true, entries: [], refs: [], commits: [], content: "")}
    end
  end

  def handle_params(_, _, socket),
    do: {:noreply, assign(socket, repos: Catalog.list(socket.assigns.current_user))}

  defp parse_tree(bytes) do
    bytes
    |> :binary.split(<<0>>, [:global])
    |> Enum.flat_map(fn row ->
      case :binary.split(row, <<9>>) do
        [header, name] ->
          case String.split(header, " ", parts: 3) do
            [mode, type, oid] -> [%{mode: mode, type: type, oid: oid, name: display(name)}]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp display(bytes) do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>),
      do: String.slice(bytes, 0, 1_000_000),
      else: "Binary content"
  end

  defp parse_refs(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(row, "\t", parts: 2) do
        [name, sha] -> [%{name: name, sha: sha}]
        _ -> []
      end
    end)
  end

  defp parse_history(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(row, "\t", parts: 3) do
        [sha, timestamp, subject] -> [%{sha: sha, timestamp: timestamp, subject: subject}]
        _ -> []
      end
    end)
  end

  defp link(repo, params),
    do: "/git/github/#{repo.owner}/#{repo.name}?" <> URI.encode_query(params)

  defp parent(path) do
    case Path.dirname(path) do
      "." -> ""
      value -> value
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
      active="git"
    >
      <section class="stack">
        <UI.heading
          title="Git repositories"
          subtitle="Read-only mirrors of public GitHub repositories."
        />
        <%= if @repo do %>
          <nav aria-label="Repository path">
            <code><.link navigate={~p"/git"}>Repositories</.link>
            / github / {@repo.owner} / {@repo.name}</code>
          </nav>
          <p :if={@repo.last_success_at} class="muted">
            Last updated
            <.timestamp at={@repo.last_success_at} zone={@time_zone} format={:datetime} />
          </p>
          <nav class="machine-tabs" aria-label="Repository views">
            <.link
              :for={tab <- ~w(tree history refs diff blame)}
              patch={link(@repo, %{view: tab, ref: @ref, path: @path})}
              aria-current={@view == tab && "page"}
            >{tab}</.link>
            <.link
              :if={@path != ""}
              patch={link(@repo, %{view: "blob", ref: @ref, path: @path})}
              aria-current={@view == "blob" && "page"}
            >file</.link>
          </nav>
          <form action={"/git/github/#{@repo.owner}/#{@repo.name}"} method="get" class="field-row">
            <input type="hidden" name="view" value="search" />
            <input type="hidden" name="ref" value={@ref} />
            <div class="field">
              <label>
                <span class="field-label">Search content</span>
                <input name="q" value={@query} placeholder="Search content" />
              </label>
            </div>
            <div class="field">
              <label>
                <span class="field-label">Kind</span>
                <span class="select">
                  <select name="kind">
                    <option value="content">Content</option>
                    <option value="paths">Paths</option>
                    <option value="commits">Commits</option>
                  </select>
                </span>
              </label>
            </div>
            <button class="console-button">Search</button>
          </form>
          <p :if={@unavailable?} role="alert" class="error">Mirror contents are unavailable.</p>
          <p :if={@view == "tree" and @path != ""}>
            <.link patch={link(@repo, %{view: "tree", ref: @ref, path: parent(@path)})}>
              ← Parent directory
            </.link>
          </p>
          <ul :if={@view == "tree"} class="tree">
            <li>
              <code>{if @path == "", do: "/", else: @path}</code>
              <ul>
                <li :for={entry <- @entries}>
                  <.link patch={
                    link(@repo, %{
                      view: if(entry.type == "tree", do: "tree", else: "blob"),
                      ref: @ref,
                      path: Path.join(@path, entry.name)
                    })
                  }>
                    <code>{entry.name}{if(entry.type == "tree", do: "/", else: "")}</code>
                  </.link>
                </li>
              </ul>
            </li>
          </ul>
          <div :if={@view == "refs"} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-auto">Ref</th><th class="width-min">Commit</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={item <- @refs}>
                  <td>
                    <.link patch={link(@repo, %{view: "tree", ref: item.name})}>{item.name}</.link>
                  </td>
                  <td><code>{String.slice(item.sha, 0, 12)}</code></td>
                </tr>
              </tbody>
            </table>
          </div>
          <div :if={@view == "history"} class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">Commit</th><th class="width-auto">Subject</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={commit <- @commits}>
                  <td>
                    <.link patch={link(@repo, %{view: "diff", ref: commit.sha, path: @path})}>
                      <code>{String.slice(commit.sha, 0, 12)}</code>
                    </.link>
                  </td>
                  <td>{commit.subject}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@view == "blob"}>
            <.link href={"/git/github/#{@repo.owner}/#{@repo.name}/raw?" <>
            URI.encode_query(%{ref: @ref, path: @path})}>Download raw file ↗</.link>
          </p>
          <pre :if={@view not in ["tree", "refs", "history"]} class="panel">{@content}</pre>
        <% else %>
          <p :if={@unavailable?} role="alert" class="error">Repository unavailable.</p>
          <ul>
            <li :for={repo <- @repos}>
              <.link navigate={link(repo, %{view: "tree"})}>
                <code>github/{repo.owner}/{repo.name}</code>
              </.link>
            </li>
          </ul>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
