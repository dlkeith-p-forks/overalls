defmodule MarshallWeb.MessageBoardLive do
  use MarshallWeb, :live_view
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       profile: :standard,
       posts: [],
       vm_id: nil,
       thread_id: nil,
       form: to_form(%{"body" => ""})
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    profile = profile(params["profile"])
    user_id = socket.assigns.current_user.id

    {:noreply,
     assign(socket,
       profile: profile,
       vm_id: params["vm_id"],
       thread_id: params["thread_id"],
       posts: Marshall.MessageBoards.list!(user_id, profile)
     )}
  end

  @impl true
  def handle_event("select_profile", %{"profile" => profile}, socket) do
    {:noreply, push_patch(socket, to: "/message-board?profile=#{profile}")}
  end

  def handle_event("post", %{"body" => body}, socket) do
    user_id = socket.assigns.current_user.id
    key = "web:" <> Ash.UUID.generate()

    case Marshall.MessageBoards.post!(user_id, socket.assigns.profile, key, body,
           vm_id: socket.assigns.vm_id,
           thread_id: socket.assigns.thread_id
         ) do
      {:ok, _post} ->
        {:noreply,
         socket
         |> assign(posts: Marshall.MessageBoards.list!(user_id, socket.assigns.profile))
         |> assign(form: to_form(%{"body" => ""}))}

      {:error, :invalid_body} ->
        {:noreply, put_flash(socket, :error, "Message cannot be empty or too large.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Message could not be saved.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="message-board" class="workspace-page">
      <header class="workspace-page__header">
        <h1>Message board</h1>
      </header>
      <nav aria-label="Machine profile">
        <%= for profile <- Marshall.MessageBoards.profiles() do %>
          <button
            phx-click="select_profile"
            phx-value-profile={profile}
            aria-current={profile == @profile}
          >
            {profile}
          </button>
        <% end %>
      </nav>
      <.form for={@form} phx-submit="post">
        <textarea name="body" placeholder="Post to this profile board"></textarea>
        <button type="submit">Post</button>
      </.form>
      <ol>
        <%= for post <- @posts do %>
          <li id={"post-#{post.id}"}><time>{post.inserted_at}</time> {post.body}</li>
        <% end %>
      </ol>
    </main>
    """
  end

  defp profile("oss"), do: :oss
  defp profile(_), do: :standard
end
