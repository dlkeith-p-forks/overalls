defmodule MarshallWeb.LaunchLive do
  @moduledoc """
  Admits a staged public repository only after complete browser authentication.

  The public capture page stores canonical source input and a visit nonce in the
  signed session. Sign-in returns here without authorizing that
  input. Connected mounts use ordinary Compute admission; a successful receipt
  is cleared through a CSRF-protected HTTP request before machine navigation.
  """
  use MarshallWeb, :live_view
  require Marshall.Events
  alias OverallsProtocol.WorkspaceSource
  alias Marshall.Compute
  alias MarshallWeb.{MachineDefaults, PendingLaunch}
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @type socket :: Phoenix.LiveView.Socket.t()
  @type status :: :waiting | :launching | :complete | :refused

  @impl true
  @spec mount(map(), map(), socket()) :: {:ok, socket()}
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        page_title: dgettext("machines", "Launch"),
        status: :waiting,
        repository: nil,
        error: nil
      )

    case PendingLaunch.read(session) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/overview", replace: true)}

      pending ->
        if connected?(socket), do: send(self(), {:launch, pending})
        repository = WorkspaceSource.display_name(pending.source)

        {:ok,
         assign(socket,
           status: :launching,
           repository: repository,
           page_title: dgettext("machines", "Launching repository")
         )}
    end
  end

  @impl true
  # @cc [owner:ghuntley,label:product;security] repository-launch-visit-dedupe
  # Admission MUST require the current stored login before
  # every message. Its key MUST bind actor, canonical source and visit, so replay
  # admits one VM using the account launch preset. Expired staged input MUST create nothing. Successful
  # admission MUST precede the signed completion receipt and matching cookie clear.
  @spec handle_info({:launch, PendingLaunch.launch()}, socket()) :: {:noreply, socket()}
  def handle_info({:launch, pending}, socket) do
    actor = socket.assigns.current_user
    source = pending.source
    key = PendingLaunch.idempotency_key(actor.id, source, pending.visit)

    with true <- pending.expires_at > System.system_time(:second) || {:error, :expired_visit},
         {:ok, request} <- request(actor, key),
         {:ok, vm} <-
           Compute.provision(
             Map.merge(request, %{idempotency_key: key, workspace_source: source}),
             actor: actor
           ) do
      receipt = PendingLaunch.receipt(actor.id, vm.id, source, pending.visit)

      {:noreply,
       socket
       |> assign(status: :complete)
       |> push_event("repository-launch-complete", %{receipt: receipt})}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason(reason))}
    end
  end

  @spec request(Marshall.Accounts.User.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp request(actor, key) do
    case Compute.repository_launch_request(%{idempotency_key: key}, actor: actor) do
      {:ok, %{request: nil}} -> new_request(actor)
      {:ok, %{request: request}} -> {:ok, request}
      error -> error
    end
  end

  @spec new_request(Marshall.Accounts.User.t()) :: {:ok, map()} | {:error, atom()}
  defp new_request(actor) do
    with {:ok, catalog} <- Compute.catalog(%{}, actor: actor),
         values = MachineDefaults.for_user(actor, :launch, catalog.images, source_required?: true),
         image_id when image_id != "" <- values["image_id"],
         {:ok, _image} <- Marshall.Compute.Images.enabled(image_id),
         {vcpu, ""} <- Integer.parse(values["vcpu"]),
         {memory_mib, ""} <- Integer.parse(values["memory_mib"]),
         {disk_gib, ""} <- Integer.parse(values["disk_gib"]),
         profile when profile in ["standard", "oss"] <- values["profile"] do
      {:ok,
       %{
         architecture: :x86_64,
         image_id: image_id,
         profile: profile,
         vcpu: vcpu,
         memory_bytes: memory_mib * 1_048_576,
         disk_bytes: disk_gib * 1_073_741_824
       }}
    else
      "" -> {:error, :image_unavailable}
      {:error, :image_unavailable} -> {:error, :image_unavailable}
      _ -> {:error, :catalog_unavailable}
    end
  end

  @spec reason(term()) :: atom()
  defp reason(reason) when is_atom(reason), do: reason
  defp reason(%Compute.Error{reason: reason}), do: reason
  defp reason(%{errors: [%Compute.Error{reason: reason} | _]}), do: reason
  defp reason(%Ash.Error.Forbidden{}), do: :forbidden
  defp reason(_), do: :launch_failed

  @spec refuse(socket(), atom()) :: socket()
  defp refuse(socket, reason) do
    Marshall.Events.emit("vm.repository_launch_refused", reason: reason)

    assign(socket,
      status: :refused,
      error: message(reason),
      page_title: dgettext("machines", "Launch refused")
    )
  end

  # Fixed public messages only; the submitted URL is never echoed back.
  @spec message(atom()) :: String.t()
  defp message(:unsupported_host),
    do:
      dgettext(
        "machines",
        "Only public repositories on GitHub, GitLab, Codeberg or Bitbucket can be launched."
      )

  defp message(:invalid_url),
    do: dgettext("machines", "That link is not a supported public repository URL.")

  defp message(:invalid_namespace),
    do: dgettext("machines", "That repository namespace is not valid.")

  defp message(:invalid_repository),
    do: dgettext("machines", "That repository name is not valid.")

  defp message(:invalid_reference),
    do: dgettext("machines", "That repository reference cannot be launched.")

  defp message(:invalid_visit),
    do: dgettext("machines", "This launch link could not be read. Open it again.")

  defp message(:expired_visit),
    do: dgettext("machines", "This launch link has expired. Open it again.")

  defp message(:insufficient_capacity),
    do:
      dgettext("machines", "There is not enough available capacity for a new machine right now.")

  defp message(reason) when reason in [:image_unavailable, :image_requirements_not_met],
    do: dgettext("machines", "The default machine image is not available right now.")

  defp message(:workspace_source_unavailable),
    do:
      dgettext(
        "machines",
        "The default image cannot open repositories. Choose an image with the current workspace service."
      )

  defp message(:forbidden), do: dgettext("machines", "Your account cannot create machines.")

  defp message(_),
    do:
      dgettext("machines", "The machine could not be created. Try again, or create one manually.")

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
    >
      <section
        id="repository-launch"
        phx-hook="RepositoryLaunchComplete"
        data-status={@status}
        class="auth-shell"
      >
        <%= if @status == :refused do %>
          <UI.panel class="auth-panel">
            <h1 class="ident">{dgettext("machines", "We couldn't launch that repository")}</h1>
            <p id="launch-error" role="alert">{@error}</p>
            <div class="row actions">
              <.link
                id="launch-create-manually"
                navigate={~p"/machines/new"}
                class="console-button primary"
              >
                {dgettext("machines", "Create a machine")}
              </.link>
              <.link navigate={~p"/overview"} class="console-button ghost">{dgettext(
                "machines",
                "Back to overview"
              )}</.link>
            </div>
          </UI.panel>
        <% else %>
          <div class="auth-panel" aria-live="polite">
            <h1 id="launch-status" class="ident">
              <%= if @repository do %>
                {dgettext("machines", "Launching")} <code>{@repository}</code>…
              <% else %>
                {dgettext("machines", "Preparing your machine…")}
              <% end %>
            </h1>
            <p class="muted">
              {dgettext("machines", "A new machine will clone the repository when it boots.")}
            </p>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
