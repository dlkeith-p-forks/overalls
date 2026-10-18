defmodule MarshallWeb.AgentThreadsLive do
  @moduledoc "VM-bound agent thread workspace."
  use MarshallWeb, :live_view
  alias Marshall.Agents.Conversation

  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount MarshallWeb.MachineWorkspace
  alias MarshallWeb.MachineWorkspace

  @impl true
  def mount(%{"id" => vm_id} = params, _session, socket) do
    socket =
      socket
      |> assign(
        vm_id: vm_id,
        thread_id: params["thread_id"],
        threads: [],
        vm: nil,
        notice: nil,
        prompt_form: prompt_form(),
        child_form: to_form(%{"title" => ""}, as: :child)
      )
      |> stream(:events, [])

    if connected?(socket), do: Process.send_after(self(), :refresh_agents, 2000)
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_params(%{"id" => vm_id} = params, _uri, socket) do
    {:noreply, socket |> assign(vm_id: vm_id, thread_id: params["thread_id"]) |> refresh()}
  end

  @impl true
  def handle_info(:refresh_agents, socket) do
    Process.send_after(self(), :refresh_agents, 2000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("prompt", %{"prompt" => %{"text" => text, "key" => key}}, socket) do
    case Marshall.Agents.submit_prompt(
           %{thread_id: socket.assigns.thread_id, prompt: text, request_key: key},
           actor: socket.assigns.current_user
         ) do
      {:ok, _turn} ->
        {:noreply,
         socket
         |> assign(prompt_form: prompt_form(), notice: "Prompt queued.")
         |> refresh()}

      _ ->
        {:noreply, assign(socket, notice: "The machine or your access is no longer available.")}
    end
  end

  def handle_event("child", %{"child" => %{"title" => title}}, socket) do
    case Conversation.spawn_child(socket.assigns.thread_id, title, socket.assigns.current_user) do
      {:ok, child} ->
        {:noreply,
         push_navigate(socket, to: ~p"/machines/#{socket.assigns.vm_id}/threads/#{child.id}")}

      _ ->
        {:noreply, assign(socket, notice: "Could not create a child thread.")}
    end
  end

  defp refresh(socket) do
    actor = socket.assigns.current_user

    with {:ok, vm} <- Conversation.machine(socket.assigns.vm_id, actor),
         {:ok, threads} <- Conversation.list(socket.assigns.vm_id, actor),
         {:ok, selected} <- selected_thread(socket.assigns.thread_id, threads, actor),
         true <- selected.root_id == hd(threads).root_id,
         {:ok, events} <- Conversation.events(selected.id, actor) do
      threads =
        if Enum.any?(threads, &(&1.id == selected.id)),
          do: threads,
          else: threads ++ [selected]

      socket
      |> MachineWorkspace.put_vm(vm)
      |> assign(threads: threads, thread_id: selected.id, notice: socket.assigns.notice)
      |> stream(:events, events, reset: true)
    else
      _ ->
        socket
        |> put_flash(:error, "Machine or agent access is no longer available.")
        |> push_navigate(to: ~p"/machines")
    end
  end

  defp selected_thread(nil, [root | _], _actor), do: {:ok, root}

  defp selected_thread(id, threads, actor) do
    case Enum.find(threads, &(&1.id == id)) do
      nil -> Conversation.get_thread(id, actor)
      selected -> {:ok, selected}
    end
  end

  defp prompt_form,
    do: to_form(%{"text" => "", "key" => Ash.UUID.generate()}, as: :prompt)

  defp event_text(%{kind: :prompt, body: body}), do: Map.get(body, "prompt", "")
  defp event_text(%{kind: :assistant, body: body}), do: Map.get(body, "text", "")
  defp event_text(%{kind: :child_spawned}), do: "Child thread created"

  defp event_text(%{kind: :turn_failed, body: %{"reason" => "capability_denied"}}),
    do: "This tool is not available for the machine profile."

  defp event_text(%{kind: kind}), do: kind |> Atom.to_string() |> String.replace("_", " ")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      compute={true}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
    >
      <section id="agent-threads" class="stack">
        <UI.machine_header
          :if={@vm}
          vm={@vm}
          connection={@machine_connection}
          power_key={@machine_power_key}
          active="agents"
        />
        <header>
          <h2>Agents</h2><p class="muted">
            Prompts wake a stopped machine when you have write access.
          </p>
        </header>
        <p :if={@notice} role="status" id="agent-notice" class="panel dashed">
          {@notice}
        </p>
        <div class="agent-grid">
          <nav aria-label="Threads" class="panel thread-list">
            <ul class="tree">
              <li>
                <strong>Threads</strong>
                <ul>
                  <li :for={thread <- @threads}>
                    <.link
                      navigate={~p"/machines/#{@vm_id}/threads/#{thread.id}"}
                      aria-current={if(thread.id == @thread_id, do: "page", else: nil)}
                    >{thread.title}</.link>
                  </li>
                </ul>
              </li>
            </ul>
            <.form
              :if={@thread_id && @vm && @vm.permissions.write}
              for={@child_form}
              id="child-thread-form"
              phx-submit="child"
              class="stack"
            >
              <.input field={@child_form[:title]} label="Child thread" maxlength="256" required />
              <button type="submit" class="console-button">Create child</button>
            </.form>
          </nav>
          <div class="stack">
            <div id="agent-events" phx-update="stream" class="panel agent-events">
              <article :for={{id, event} <- @streams.events} id={id} class="agent-message">
                <p class="muted"><strong>{event.kind}</strong></p>
                <pre>{event_text(event)}</pre>
              </article>
            </div>
            <.form
              :if={@thread_id && @vm && @vm.permissions.write}
              for={@prompt_form}
              id="agent-prompt-form"
              phx-submit="prompt"
              class="panel"
            >
              <.input
                field={@prompt_form[:text]}
                type="textarea"
                label="Prompt"
                maxlength="65536"
                required
              />
              <input type="hidden" name="prompt[key]" value={@prompt_form[:key].value} />
              <button type="submit" class="console-button primary" phx-disable-with="Sending…">Send prompt</button>
            </.form>
            <p :if={@vm && !@vm.permissions.write} class="muted">
              You can read these threads. Ask for operator or manager access to send prompts.
            </p>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
