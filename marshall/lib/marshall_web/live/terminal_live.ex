defmodule MarshallWeb.TerminalLive do
  @moduledoc "Multi-terminal workspace: session sidebar, pane area and read-only boot log."
  use MarshallWeb, :live_view
  require Marshall.Events
  alias Marshall.Compute
  alias Marshall.Terminal.Authority
  alias Marshall.Android.DisplayTickets
  alias MarshallWeb.{MachineWorkspace, TerminalOpening}
  import MarshallWeb.TerminalOpening, only: [is_retryable: 1]

  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount MarshallWeb.MachineWorkspace

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Logger.metadata(marshall_terminal: true)

    socket =
      socket
      |> assign(
        vm: nil,
        opening: TerminalOpening.new(),
        opening_task: nil,
        android_display?: false,
        android_display_notice: nil,
        sessions_empty?: true,
        notice: nil,
        opening_notice: nil,
        boot_log_cursor: 0,
        boot_log?: false,
        wake_on_mount?: true,
        boot_log_text: ""
      )
      |> stream(:terminal_sessions, [])

    case Compute.get_vm(%{vm_id: id}, actor: socket.assigns.current_user) do
      {:ok, vm} ->
        if connected?(socket), do: Process.send_after(self(), :refresh_terminals, 2000)
        {:ok,
         socket
         |> MachineWorkspace.put_vm(vm)
         |> assign(android_display?: get_in(vm, [:guest_capabilities, :android_display]) == true),
         layout: false}

      _ ->
        # ADR-0140: an unreachable database is not evidence the machine is
        # gone. Crash instead, so the browser retries this page rather than
        # leaving the open terminals for the machine list.
        unless Marshall.Repo.answers?(),
          do: raise(DBConnection.ConnectionError, "database unavailable")

        {:ok,
         socket
         |> put_flash(:error, gettext("Machine not found."))
         |> push_navigate(to: ~p"/machines")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, boot_log?: params["view"] == "boot-log")

    if connected?(socket) do
      {:noreply, refresh_sessions(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("android_display_ticket", %{"mode" => mode}, socket)
      when mode in ["viewer", "controller"] do
    display_mode = String.to_existing_atom(mode)

    case DisplayTickets.issue(socket.assigns.vm, socket.assigns.current_user, display_mode) do
      {:ok, ticket} ->
        {:noreply,
         socket
         |> assign(android_display_notice: gettext("Display relay ticket issued."))
         |> push_event("android_display_ticket", %{ticket: ticket, mode: mode})}

      {:error, :forbidden} ->
        {:noreply, assign(socket, android_display_notice: gettext("Android display is unavailable."))}
    end
  end

  def handle_event("android_display_ticket", _params, socket),
    do: {:noreply, assign(socket, android_display_notice: gettext("Android display is unavailable."))}

  def handle_event("terminal_new", %{"request_id" => request_id}, socket)
      when is_binary(request_id) do
    case Authority.open_personal_session(
           socket.assigns.vm,
           socket.assigns.current_user,
           request_id
         ) do
      {:ok, session} ->
        {:reply, %{status: "ready", request_id: request_id, session_id: session.id},
         refresh_sessions(
           assign(socket,
             notice: nil,
             opening_notice: nil,
             opening: TerminalOpening.finish(socket.assigns.opening, :ready)
           )
         )}

      {:error, reason}
      when is_retryable(reason) ->
        {:reply, %{status: "pending", request_id: request_id},
         assign(socket,
           opening_notice: nil,
           notice:
             gettext(
               "Opening terminal; recovering the same request if the connection was interrupted."
             )
         )}

      {:error, reason} ->
        {:reply, %{status: "failed", request_id: request_id},
         assign(socket, notice: notice(reason), opening_notice: notice(reason))}
    end
  end

  # @cc [owner:ghuntley,label:security] terminal-ticket-requires-fresh-login
  # terminal_ticket MUST verify the current authenticated user against the
  # registry session and Cedar before minting a single-use attach ticket; the
  # ticket itself carries the authority and is never reassigned in state.
  def handle_event("terminal_ticket", %{"session_id" => session_id}, socket) do
    actor = socket.assigns.current_user

    with {:ok, session} <- Marshall.Terminal.Authority.session_for(session_id, actor, :connect),
         {:ok, ticket} <- Marshall.Terminal.Authority.ticket(session, actor) do
      {:noreply, push_event(socket, "terminal_ticket", %{session_id: session_id, ticket: ticket})}
    else
      {:error, :terminal_open_pending} ->
        {:noreply, assign(socket, notice: gettext("Resuming machine; waiting for capacity…"))}

      refusal ->
        Marshall.Events.emit("terminal.ticket_refused", reason: ticket_refusal(refusal))
        {:noreply, assign(socket, notice: gettext("Terminal access ended."))}
    end
  end

  def handle_event("terminal_kill", %{"session_id" => session_id}, socket) do
    actor = socket.assigns.current_user

    with {:ok, session} <- Marshall.Terminal.Authority.session_for(session_id, actor),
         :ok <- Marshall.Terminal.Authority.close_session(session, actor) do
      {:noreply,
       refresh_sessions(
         assign(socket, opening: TerminalOpening.finish(socket.assigns.opening, :closed))
       )}
    else
      {:error, :terminal_close_pending} ->
        {:noreply,
         assign(socket,
           notice: gettext("Terminal close requested; waiting for guest confirmation.")
         )}

      _ ->
        {:noreply, refresh_sessions(socket)}
    end
  end

  def handle_event(
        "terminal_share",
        %{"session_id" => id, "email" => email, "action" => action},
        socket
      )
      when action in ["share", "revoke"] do
    actor = socket.assigns.current_user

    with {:ok, session} <- Marshall.Terminal.Authority.session_for(id, actor),
         :ok <-
           Marshall.Terminal.Sharing.set(
             session,
             actor,
             email,
             if(action == "share", do: :shared, else: :revoked)
           ) do
      {:reply, %{ok: true}, assign(socket, notice: gettext("Terminal viewing access updated."))}
    else
      _ ->
        {:reply, %{ok: false},
         assign(socket,
           notice:
             gettext(
               "Unable to update terminal sharing. The recipient must have machine access before sharing."
             )
         )}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] boot-log-replies-correlate-request
  # Boot-log results MUST return through the originating hook request's reply,
  # including refusal, so a paused browser can discard its obsolete callback.
  # Payload bytes MUST NOT enter LiveView assigns or unsolicited pushed events.
  def handle_event("terminal_boot_log", %{"cursor" => cursor}, socket) do
    cursor = parse_cursor(cursor, socket.assigns.boot_log_cursor)

    case Marshall.Terminal.Authority.boot_log(
           socket.assigns.vm,
           socket.assigns.current_user,
           cursor
         ) do
      {:ok, %{next: next, bytes: bytes}} ->
        {:reply, %{ok: true, next: next, text: Base.encode64(bytes)},
         socket
         |> assign(
           boot_log_cursor: next,
           notice: if(socket.assigns.boot_log?, do: nil, else: socket.assigns.notice)
         )}

      {:error, _reason} ->
        {:reply, %{ok: false},
         assign(socket,
           notice: gettext("The boot log is unavailable for the current machine execution.")
         )}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh_terminals, socket) do
    Process.send_after(self(), :refresh_terminals, 2000)
    {:noreply, refresh_sessions(socket)}
  end

  def handle_info(:terminal_opened, socket), do: {:noreply, refresh_sessions(socket)}

  # @cc [owner:ghuntley,label:recovery] stale-terminal-replies-are-inert
  # Replies left by pre-upgrade controls MUST NOT crash the workspace, change
  # its sessions or trigger a new opening. Fresh-login hooks still apply.
  def handle_info({:relay_reply, reference, {status, _result}}, socket)
      when is_reference(reference) and status in [:ok, :error],
      do: {:noreply, socket}

  def handle_info({ref, result}, %{assigns: %{opening_task: ref}} = socket)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, opened(assign(socket, opening_task: nil), result)}
  end

  # A crashed opening is inconclusive: the durable receipt makes the next
  # refresh's attempt idempotent.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{opening_task: ref}} = socket
      ),
      do: {:noreply, assign(socket, opening_task: nil)}

  @impl true
  def terminate(_reason, _socket), do: :ok

  defp refresh_sessions(socket) do
    case Compute.get_vm(%{vm_id: socket.assigns.vm.id}, actor: socket.assigns.current_user) do
      {:ok, vm} -> refresh_current_sessions(MachineWorkspace.put_vm(socket, vm))
      _ -> MachineWorkspace.return_after_access_loss(socket, :read)
    end
  end

  # @cc [owner:ghuntley,label:product] terminal-opening-failure-visible
  # A failed explicit opening MUST remain visible across session refreshes,
  # including when another shell is live. A retry or new execution clears it.

  # @cc [owner:ghuntley,label:recovery] terminal-startup-presentation
  # Non-running executions MUST NOT query guest sessions. Retryable listing
  # failures MUST show preparation or reconnection while preserving existing
  # sessions and any definitive opening failure; they MUST NOT imply shell exit.

  # @cc [owner:ghuntley,label:security;product] boot-log-view-skips-guest-opening
  # The explicit Boot log view MUST refresh current VM read authority without
  # listing or automatically opening guest sessions. Its bytes MUST still use
  # the independently authorized bounded host boot-log operation.
  defp refresh_current_sessions(%{assigns: %{boot_log?: true}} = socket), do: socket

  # @cc [owner:ghuntley,label:recovery;capacity] terminal-server-refresh-is-passive
  # The first terminal-page connection MAY join paused wake demand. Subsequent
  # server refreshes MUST observe without waking; reopening or an explicit
  # browser attach remains a new connection. Boot-log views never create demand.
  defp refresh_current_sessions(socket) do
    wake_on_mount? = socket.assigns.wake_on_mount?
    socket = assign(socket, wake_on_mount?: false)

    socket =
      if socket.assigns.opening.execution == socket.assigns.vm.execution_ref,
        do: socket,
        else:
          assign(socket,
            opening_notice: nil,
            notice: nil,
            opening:
              TerminalOpening.for_execution(
                socket.assigns.opening,
                socket.assigns.vm.execution_ref
              )
          )

    vm = socket.assigns.vm

    if vm.desired_state == :running and vm.observed_state == :running do
      list_current_sessions(socket)
    else
      notice =
        case Authority.ensure_awake(
               vm,
               socket.assigns.current_user,
               "read",
               if(wake_on_mount?, do: :connect, else: :observe)
             ) do
          {:error, :terminal_open_pending} -> gettext("Resuming machine; waiting for capacity…")
          _ -> socket.assigns.opening_notice || machine_waiting_notice(vm)
        end

      assign(socket, notice: notice)
    end
  end

  @spec machine_waiting_notice(map()) :: String.t()
  defp machine_waiting_notice(%{guest_capabilities: %{available: true, terminal: false}}),
    do:
      gettext(
        "This machine's image has no terminal agent, so the browser terminal is unavailable."
      )

  defp machine_waiting_notice(%{observed_state: :failed}),
    do: gettext("Machine startup failed. Check the machine status and boot log.")

  defp machine_waiting_notice(%{desired_state: :stopped}),
    do: gettext("Machine is stopping or stopped. Choose Start to open a terminal.")

  defp machine_waiting_notice(%{desired_state: :paused}),
    do: gettext("Machine is paused. Resume it or reopen this terminal page.")

  defp machine_waiting_notice(_vm), do: gettext("Waiting for the machine to start…")

  defp list_current_sessions(socket) do
    case Marshall.Terminal.Authority.list_sessions(
           socket.assigns.vm,
           socket.assigns.current_user,
           :observe
         ) do
      {:ok, sessions} ->
        notice =
          if Enum.any?(sessions, &(&1.kill_status == :pending)),
            do: gettext("Terminal close requested; waiting for guest confirmation."),
            else:
              socket.assigns.opening_notice ||
                if(socket.assigns.opening.phase == :failed, do: socket.assigns.notice)

        socket = assign(socket, notice: notice)
        socket = auto_open(socket, sessions)

        writable =
          Marshall.Terminal.Authority.writable?(socket.assigns.vm.id, socket.assigns.current_user)

        sessions =
          Enum.map(sessions, fn session ->
            %{
              id: session.id,
              display_name: MarshallWeb.TerminalNames.display_name(session.id),
              guest_user: session.user,
              viewers: session.viewers,
              cols: session.cols,
              rows: session.rows,
              created_ms: session.created_ms,
              last_ms: session.last_ms,
              can_kill:
                session.kill_status == :idle and
                  session.owner_id == socket.assigns.current_user.id and writable,
              title: nil
            }
          end)

        socket
        |> assign(:sessions_empty?, sessions == [])
        |> stream(:terminal_sessions, sessions, reset: true)
        |> push_event("terminal_sessions", %{sessions: sessions})

      {:error, :forbidden} ->
        MachineWorkspace.return_after_access_loss(socket, :read)

      {:error, reason} when is_retryable(reason) ->
        pending =
          if socket.assigns.opening.phase in [:waiting, :opening],
            do: gettext("Preparing your terminal…"),
            else: gettext("Reconnecting to the terminal service…")

        assign(socket, notice: socket.assigns.opening_notice || pending)

      {:error, reason} ->
        assign(socket, notice: socket.assigns.opening_notice || notice(reason))
    end
  end

  defp auto_open(socket, sessions) do
    vm = socket.assigns.vm

    {opening, action} =
      TerminalOpening.observe(
        socket.assigns.opening,
        vm.execution_ref,
        vm.desired_state == :running and vm.observed_state == :running,
        vm.permissions.write,
        sessions != []
      )

    socket = assign(socket, opening: opening)

    # @cc [owner:ghuntley,label:recovery;capacity] terminal-opening-off-liveview
    # Automatic opening MUST run in a supervised task, never block the LiveView
    # process, and at most one opening per view may be in flight; refreshes
    # during it MUST NOT start another.
    if action == :open and is_nil(socket.assigns.opening_task) do
      user = socket.assigns.current_user

      task =
        Task.Supervisor.async_nolink(Marshall.Terminal.OpeningTasks, fn ->
          Authority.open_personal_session(vm, user, :default, :observe)
        end)

      assign(socket,
        opening_task: task.ref,
        notice: socket.assigns.opening_notice || gettext("Preparing your terminal…")
      )
    else
      socket
    end
  end

  defp opened(socket, {:ok, _session}) do
    # Refresh after the durable receipt so the existing browser hook attaches.
    send(self(), :terminal_opened)
    assign(socket, opening: TerminalOpening.finish(socket.assigns.opening, :ready))
  end

  defp opened(socket, {:error, reason}) do
    opening = TerminalOpening.failed(socket.assigns.opening, reason)
    pending? = TerminalOpening.pending?(opening)

    assign(socket,
      opening: opening,
      opening_notice: if(pending?, do: nil, else: notice(reason)),
      notice:
        cond do
          not pending? -> notice(reason)
          reason == :rejected -> gettext("Preparing your guest account…")
          true -> gettext("Preparing your terminal…")
        end
    )
  end

  defp parse_cursor(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {cursor, ""} when cursor >= 0 -> cursor
      _ -> fallback
    end
  end

  defp parse_cursor(_, fallback), do: fallback

  defp notice(:too_many_terminal_sessions),
    do: gettext("Terminal limit reached for this machine.")

  defp notice(:forbidden), do: gettext("You do not have terminal access to this machine.")

  defp notice(:terminal_unavailable),
    do: gettext("Terminals are unavailable while the host is offline.")

  defp notice(:unknown_session),
    do: gettext("Your previous shell has closed. Choose New to open another terminal.")

  defp notice(:opening_expired),
    do: gettext("The previous opening has ended. Choose New to try again.")

  defp notice(:rejected),
    do:
      gettext(
        "Your guest account could not be prepared. Check that the guest account service is available, then choose New to retry."
      )

  defp notice(:limit), do: gettext("The guest cannot host more terminal sessions.")

  defp notice(_), do: gettext("The terminal could not be opened.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
    >
      <section :if={@vm} id="terminal-workspace" class="stack">
        <UI.machine_header
          vm={@vm}
          connection={@machine_connection}
          power_key={@machine_power_key}
          active={if @boot_log?, do: "boot-log", else: "terminal"}
        />
        <div
          :if={!@boot_log? && (@vm.desired_state != :running || @vm.observed_state != :running)}
          id="terminal-machine-state"
          role="status"
        >
          <%= if @vm.desired_state == :stopped do %>
            {gettext(
              "This machine is stopped. Start it to open your terminal. Your files are retained."
            )}
          <% else %>
            {gettext("Your terminal will open when the machine is running and ready.")}
          <% end %>
        </div>
        <p :if={@notice} id="terminal-notice" role="status">
          {@notice}
        </p>

        <div
          id="terminal-client"
          phx-hook="TerminalWorkspace"
          data-vm-id={@vm.id}
          data-view={if @boot_log?, do: "boot-log", else: "terminal"}
          class="machine-terminal-grid"
        >
          <aside class="machine-terminal-sidebar">
            <div class="row">
              <button
                :if={!@boot_log?}
                id="terminal-create"
                disabled={
                  !@vm.permissions.write || @vm.desired_state != :running ||
                    @vm.observed_state != :running
                }
                type="button"
                class="console-button primary"
              >
                {gettext("+ New")}
              </button>
            </div>
            <div
              id="terminal-sidebar-list"
              phx-update="stream"
              role="listbox"
              aria-label={gettext("Terminal sessions")}
            >
              <div
                :for={{dom_id, session} <- @streams.terminal_sessions}
                id={dom_id}
                class="terminal-session-row"
              >
                <button
                  type="button"
                  id={"terminal-item-#{session.id}"}
                  data-terminal-select={session.id}
                  role="option"
                  aria-selected="false"
                  aria-label={
                    ngettext(
                      "Terminal %{name}, %{count} viewer, created %{created}",
                      "Terminal %{name}, %{count} viewers, created %{created}",
                      session.viewers,
                      name: session.display_name,
                      created: session.created_ms
                    )
                  }
                  class="terminal-session"
                >
                  <span aria-hidden="true"><span class="terminal-unread-dot"></span></span>
                  <span>
                    <span class="terminal-label">{session.display_name}</span>
                    <span class="terminal-meta">{ngettext(
                      "%{user} · %{count} viewing",
                      "%{user} · %{count} viewing",
                      session.viewers,
                      user: session.guest_user
                    )}</span>
                  </span>
                </button>
                <button
                  :if={session.can_kill}
                  type="button"
                  data-terminal-share={session.id}
                  aria-label={gettext("Share terminal %{value1}", value1: session.display_name)}
                  title={gettext("Share view")}
                  class="console-button ghost"
                >+</button>
                <button
                  :if={session.can_kill}
                  type="button"
                  data-terminal-kill={session.id}
                  aria-label={gettext("Close terminal %{value1}", value1: session.display_name)}
                  title={gettext("Close session")}
                  class="console-button ghost"
                >×</button>
              </div>
            </div>
            <div id="terminal-empty" class={[!@sessions_empty? && "hidden"]}>
              <%= cond do %>
                <% @boot_log? -> %>
                  {gettext("Read-only host boot log. Guest terminal readiness is not required.")}
                <% !@vm.permissions.write -> %>
                  {gettext("No shared terminals are available to view.")}
                <% @opening.phase in [:waiting, :opening] -> %>
                  {gettext("Your personal terminal opens when the machine is ready.")}
                <% true -> %>
                  {gettext("No terminals are open. Choose New to open your personal shell.")}
              <% end %>
            </div>
            <div id="terminal-sidebar-tools" phx-update="ignore">
              <button id="terminal-boot-log" type="button">{gettext("Boot log")}</button>
            </div>
          </aside>

          <section :if={@android_display?} id="android-display" class="stack" aria-labelledby="android-display-heading">
            <h2 id="android-display-heading">{gettext("Android display")}</h2>
            <p>{gettext("The software-rendered Android display uses the machine relay.")}</p>
            <div class="row">
              <button type="button" phx-click="android_display_ticket" phx-value-mode="viewer">
                {gettext("Open display")}
              </button>
              <button type="button" phx-click="android_display_ticket" phx-value-mode="controller">
                {gettext("Request control")}
              </button>
            </div>
            <p :if={@android_display_notice} role="status">{@android_display_notice}</p>
          </section>

          <div id="terminal-display" class="machine-terminal-display">
            <div id="terminal-display-ui" phx-update="ignore">
              <div class="terminal-toolbar">
                <p id="terminal-status" phx-update="ignore" role="status" data-status="connecting">
                  {gettext("Connecting…")}
                </p>
                <div class="terminal-tools">
                  <span id="terminal-input-hint" phx-update="ignore">{gettext("Type to interact")}</span>
                  <button
                    type="button"
                    data-terminal-tool="rename"
                    aria-label={gettext("Rename terminal")}
                    title={gettext("Rename in this browser")}
                  >{gettext("rename")}</button>
                  <button
                    type="button"
                    data-terminal-tool="search"
                    aria-label={gettext("Search scrollback")}
                    title={gettext("Search (Ctrl+F)")}
                  >{gettext("find")}</button>
                  <button
                    type="button"
                    data-terminal-tool="zoom-out"
                    aria-label={gettext("Decrease terminal font size")}
                  >{gettext("A−")}</button>
                  <button
                    type="button"
                    data-terminal-tool="zoom-in"
                    aria-label={gettext("Increase terminal font size")}
                  >{gettext("A+")}</button>
                  <button
                    id="terminal-fullscreen"
                    type="button"
                    data-terminal-tool="fullscreen"
                    aria-label={gettext("Enter full screen")}
                    aria-pressed="false"
                    title={gettext("Enter full screen")}
                  >{gettext("full")}</button>
                </div>
              </div>
              <div id="terminal-search-bar" role="search" class="hidden">
                <label class="sr-only" for="terminal-search-query">{gettext(
                  "Search terminal scrollback"
                )}</label>
                <input
                  id="terminal-search-query"
                  type="search"
                  maxlength="256"
                  placeholder={gettext("Find in scrollback")}
                />
                <button
                  type="button"
                  data-terminal-tool="search-previous"
                  aria-label={gettext("Previous match")}
                >↑</button>
                <button
                  type="button"
                  data-terminal-tool="search-next"
                  aria-label={gettext("Next match")}
                >↓</button>
                <button
                  type="button"
                  data-terminal-tool="search-close"
                  aria-label={gettext("Close search")}
                >×</button>
                <span id="terminal-search-result" role="status"></span>
              </div>
              <div id="terminal-pane-holder"></div>
              <div id="terminal-boot-view" class="hidden">
                <label>
                  <input id="terminal-boot-autoscroll" type="checkbox" checked /> {gettext(
                    "Follow boot output"
                  )}
                </label>
                <div
                  id="terminal-boot-xterm"
                  role="region"
                  aria-label={gettext("Read-only boot console")}
                >
                </div>
              </div>
            </div>
          </div>
          <div id="terminal-share-dialog-region" phx-update="ignore">
            <dialog id="terminal-share-dialog" aria-labelledby="terminal-share-heading">
              <h2 id="terminal-share-heading">{gettext("Share this terminal")}</h2>
              <p>
                {gettext(
                  "Viewing only, even for machine operators. The recipient must already have access to this machine."
                )}
              </p>
              <div class="field">
                <label for="terminal-share-email">
                  <span class="field-label">{gettext("Account email")}</span>
                  <input id="terminal-share-email" type="email" maxlength="320" />
                </label>
              </div>
              <p id="terminal-share-result" role="status"></p>
              <div class="dialog-actions">
                <button type="button" data-terminal-tool="share-submit" class="console-button primary">
                  {gettext("Allow viewing")}
                </button>
                <button type="button" data-terminal-tool="share-revoke" class="console-button">
                  {gettext("Revoke")}
                </button>
                <button type="button" data-terminal-tool="share-close" class="console-button">
                  {gettext("Cancel")}
                </button>
              </div>
            </dialog>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @spec ticket_refusal(term()) ::
          :unknown_session
          | :forbidden
          | :terminal_unavailable
          | :vm_deleted
          | :unavailable
          | :other
  defp ticket_refusal({:error, reason})
       when reason in [
              :unknown_session,
              :forbidden,
              :terminal_unavailable,
              :vm_deleted,
              :unavailable
            ],
       do: reason

  defp ticket_refusal(_), do: :other
end
