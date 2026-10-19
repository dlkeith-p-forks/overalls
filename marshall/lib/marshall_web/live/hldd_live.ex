defmodule MarshallWeb.HLDDLive do
  @moduledoc "The authenticated Overalls design and operations handbook."
  use MarshallWeb, :live_view
  on_mount({MarshallWeb.LiveUserAuth, :live_user_required})
  alias Marshall.Handbook

  # @cc [owner:ghuntley,label:security] handbook-current-reader
  # Reading the handbook MUST require a current completed login, without requiring
  # administrative membership. The page MUST NOT read live operational data.
  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, assign(socket, contents: Handbook.contents())}
  end

  # @cc [owner:ghuntley,label:performance;security] handbook-section-payload
  # The index MUST include no chapter bodies. Section requests MUST select exactly
  # one compiled chapter; unknown identifiers MUST return to contents without
  # selecting a filesystem path. Navigation MUST replace the previous body and hook.
  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(%{"section" => id}, _uri, %{assigns: %{live_action: :section}} = socket) do
    case Handbook.fetch_chapter(id) do
      {:ok, chapter} ->
        {before, [_current | following]} =
          Enum.split_while(socket.assigns.contents, &(&1.id != id))

        {:noreply,
         assign(socket,
           page_title: dgettext("shared", "%{value1} · HLDD", value1: chapter.title),
           chapter: chapter,
           previous: List.last(before),
           following: List.first(following)
         )}

      :error ->
        {:noreply, redirect(socket, to: ~p"/hldd")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       page_title: dgettext("shared", "HLDD"),
       chapter: nil,
       previous: nil,
       following: nil
     )}
  end

  # @cc [owner:ghuntley,label:product] handbook-content-language-direction
  # Source chapter bodies and titles MUST declare English and LTR direction even
  # when the surrounding application chrome uses a different reader locale.
  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      active="hldd"
    >
      <div id="hldd" class="hldd">
        <header class="hldd-heading">
          <p class="muted">{dgettext("shared", "HLDD · Design and operations")}</p>
          <h1>{dgettext("shared", "Overalls")}</h1>
          <p>
            {dgettext("shared", "A reference for the system, its configuration, and its operation.")}
          </p>
        </header>
        <nav :if={!@chapter} id="hldd-index" aria-label={dgettext("shared", "Handbook contents")}>
          <ol class="hldd-index">
            <li :for={{section, number} <- Enum.with_index(@contents, 1)}>
              <.link patch={~p"/hldd/#{section.id}"} lang="en" dir="ltr">
                <span class="hldd-section-number">{number}</span>{section.title}
              </.link>
            </li>
          </ol>
        </nav>
        <div :if={@chapter} class="hldd-grid">
          <aside class="hldd-contents">
            <p><.link patch={~p"/hldd"}>{dgettext("shared", "← All sections")}</.link></p>
            <details open>
              <summary>{dgettext("shared", "Contents")}</summary>
              <nav aria-label={dgettext("shared", "Handbook contents")}>
                <.link
                  :for={section <- @contents}
                  patch={~p"/hldd/#{section.id}"}
                  aria-current={section.id == @chapter.id && "page"}
                  lang="en"
                  dir="ltr"
                >
                  {section.title}
                </.link>
              </nav>
            </details>
          </aside>
          <div>
            <article
              id={"hldd-content-#{@chapter.id}"}
              class="hldd-prose prose"
              data-hldd-section={@chapter.id}
              lang="en"
              dir="ltr"
              phx-hook="Handbook"
              phx-update="ignore"
            >
              <section id={@chapter.id}>{raw(@chapter.html)}</section>
            </article>
            <nav class="hldd-pagination" aria-label={dgettext("shared", "Adjacent sections")}>
              <.link :if={@previous} patch={~p"/hldd/#{@previous.id}"} rel="prev">
                ← <span lang="en" dir="ltr">{@previous.title}</span>
              </.link>
              <.link :if={@following} patch={~p"/hldd/#{@following.id}"} rel="next">
                <span lang="en" dir="ltr">{@following.title}</span> →
              </.link>
            </nav>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
