defmodule MarshallWeb.AgentCLIApprovalLive do
  @moduledoc "Explicit browser approval for a VM-scoped agent CLI secret."
  use MarshallWeb, :live_view
  alias Marshall.Agents.{CLIAccess, Conversation}

  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, vm_id: nil, code: nil, vm: nil)}

  @impl true
  def handle_params(%{"vm_id" => vm_id, "code" => code}, _, socket) do
    case Conversation.machine(vm_id, socket.assigns.current_user) do
      {:ok, %{permissions: %{write: true}} = vm} ->
        {:noreply, assign(socket, vm_id: vm_id, code: code, vm: vm)}

      _ ->
        {:noreply, unavailable(socket)}
    end
  end

  # @cc [owner:ghuntley,label:security] agent-cli-explicit-browser-approval
  # GET displays the request; only an authenticated, current-login form event
  # may bind the browser actor to the URL's VM and secret digest.
  @impl true
  def handle_event("approve", _, %{assigns: %{vm_id: vm_id, code: code}} = socket)
      when is_binary(vm_id) and is_binary(code) do
    case CLIAccess.approve(vm_id, code, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(code: nil)
         |> put_flash(:info, gettext("Agent CLI approved for one hour. Return to your terminal."))
         |> push_navigate(to: ~p"/machines/#{vm_id}/threads")}

      _ ->
        {:noreply, unavailable(socket)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, unavailable(socket)}

  defp unavailable(socket) do
    socket
    |> assign(vm_id: nil, code: nil, vm: nil)
    |> put_flash(
      :error,
      gettext("This agent CLI approval is unavailable. Start again in your terminal.")
    )
  end

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
      <section class="stack">
        <h1>{gettext("Approve agent CLI")}</h1>
        <p :if={@vm}>{gettext("Machine:")} <code>{@vm.name}</code></p>
        <p :if={@code}>
          {gettext("Match this request code with your terminal before approving:")}
          <strong class="font-mono">{String.slice(@code, 0, 12)}</strong>
        </p>
        <.form :if={@code && @vm} for={to_form(%{})} id="agent-cli-approval" phx-submit="approve">
          <button
            type="submit"
            class="console-button primary"
            phx-disable-with={gettext("Approving…")}
          >
            {gettext("Approve CLI access")}
          </button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
