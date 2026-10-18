defmodule MarshallWeb.WorkspaceComponents do
  @moduledoc "Shared Overalls panels, headings and machine workspace navigation."
  use MarshallWeb, :html

  # @cc [owner:ghuntley,label:product] workspace-controls-preserve-authority
  # Presentation components MUST preserve caller-provided action attributes and
  # escaped content. Navigation and badges MUST NOT authorize domain operations.
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :title, :string, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true
  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    ~H"""
    <section id={@id} class={["panel", @class]} {@rest}>
      <header :if={@title || @actions != []}>
        <h2 :if={@title}>{@title}</h2>
        <div :if={@actions != []} class="row">{render_slot(@actions)}</div>
      </header>
      <div class="panel-body">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions
  @spec heading(map()) :: Phoenix.LiveView.Rendered.t()
  def heading(assigns) do
    ~H"""
    <header class="page-heading">
      <div>
        <h1>{@title}</h1><p :if={@subtitle}>{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="heading-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :id, :string, default: nil
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :action
  @spec empty(map()) :: Phoenix.LiveView.Rendered.t()
  def empty(assigns) do
    ~H"""
    <div id={@id} class="empty-state">
      <h2>{@title}</h2><p>{render_slot(@inner_block)}</p>
      <div :if={@action != []} class="row actions">{render_slot(@action)}</div>
    </div>
    """
  end

  @spec machine_state(map()) :: String.t()
  def machine_state(%{desired_state: :deleted}), do: "Deleting"
  def machine_state(%{desired_state: :stopped, observed_state: :running}), do: "Stopping"

  def machine_state(%{desired_state: :running, observed_state: state})
      when state in [:pending, :stopped], do: "Starting"

  def machine_state(%{observed_state: state}), do: String.capitalize(to_string(state))

  attr :vm, :map, required: true
  attr :active, :string, default: "terminal"
  # @cc [owner:ghuntley,label:security;product] workspace-agentless-image-hides-guest-controls
  # Terminal and SSH connection controls MUST render only when the
  # projected guest_capabilities grant that capability; an image without it or a
  # missing projection hides the control and shows the explanation instead.
  # Hiding is presentation only; server-side authorities refuse independently.

  # @cc [owner:ghuntley,label:product;security] workspace-host-boot-log-entry
  # Machine readers MUST have a distinct Boot log entry regardless of guest
  # terminal capability. This entry MUST select read-only host diagnostics;
  # navigation MUST NOT grant terminal or host-file authority.

  # @cc [owner:ghuntley,label:product] workspace-global-thread-entry
  # Machine workspace navigation MUST omit the machine-scoped Agents entry;
  # the global Threads navigation is the primary entry to agent work.
  @spec machine_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def machine_nav(assigns) do
    ~H"""
    <nav class="machine-tabs" aria-label="Machine workspace">
      <.link
        :if={capability?(@vm, :terminal)}
        navigate={~p"/machines/#{@vm.id}"}
        aria-current={@active == "terminal" && "page"}
      >Terminal</.link>
      <.link
        :if={@vm.permissions.read}
        id="machine-boot-log"
        navigate={~p"/machines/#{@vm.id}/terminals?view=boot-log"}
        aria-current={@active == "boot-log" && "page"}
      >Boot log</.link>
      <.link
        :if={@vm.permissions.manage && OverallsProtocol.ProfilePolicy.allows?(@vm.profile, :sharing)}
        navigate={~p"/machines/#{@vm.id}/access"}
        aria-current={@active == "access" && "page"}
      >Access</.link>
      <.link
        navigate={~p"/machines/#{@vm.id}/settings"}
        aria-current={@active == "settings" && "page"}
      >Settings</.link>
    </nav>
    """
  end

  @doc "The projected image display name shown as the machine's operating system, or nil."
  @spec operating_system(map()) :: String.t() | nil
  def operating_system(vm) do
    case Map.get(vm, :image_name) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  attr :vm, :map, required: true
  attr :id, :string, required: true
  # @cc [owner:ghuntley,label:product] workspace-operating-system-label
  # The operating-system label MUST show only the projected image display name
  # (`image_name`) as text. A missing or blank name MUST render no element at
  # all, never "nil" or a placeholder; the label never conveys state by colour.
  @spec os_label(map()) :: Phoenix.LiveView.Rendered.t()
  def os_label(assigns) do
    assigns = assign(assigns, :name, operating_system(assigns.vm))

    ~H"""
    <span :if={@name} id={@id} class="status-label os-label" data-tone="muted">{@name}</span>
    """
  end

  attr :vm, :map, required: true
  attr :connection, :map, default: nil
  attr :power_key, :string, required: true
  attr :active, :string, required: true
  # @cc [owner:ghuntley,label:security;product] workspace-editor-eligibility
  # Every editor control MUST require current projected write/profile authority,
  # Customer ownership, both desired/observed running and available image status.
  # Unsupported images MUST show a disabled control with a new-image explanation;
  # missing/unknown status MUST fail closed. Rendering MUST NOT read resources or
  # allocate accounts; the displayed status MUST NOT authorize the launch route.
  @spec machine_header(map()) :: Phoenix.LiveView.Rendered.t()
  def machine_header(assigns) do
    assigns = assign(assigns, :editor_control, editor_control(assigns.vm))

    ~H"""
    <div id="machine-workspace-header" class="machine-workspace-header">
      <header class="machine-heading">
        <div class="machine-summary">
          <div class="machine-title">
            <h1>{@vm.name}</h1>
            <span id="machine-state" class="status-label" data-state={@vm.observed_state}>{machine_state(
              @vm
            )}</span>
            <.os_label vm={@vm} id="machine-os" />
          </div>
          <p class="machine-facts muted">
            {@vm.vcpu} vCPU · {workspace_gib(@vm.memory_bytes)} GiB memory · {workspace_gib(
              @vm.disk_bytes
            )} GiB disk · {profile_name(@vm.profile)}
          </p>
          <p class="machine-identity">
            <span class="muted">ID</span>
            <code id="machine-id">{@vm.id}</code>
            <button
              type="button"
              class="console-button compact"
              data-copy-command="machine-id"
              data-copy-label="Machine ID"
              aria-label="Copy machine ID"
            >Copy</button>
          </p>
        </div>
        <div class="machine-actions">
          <div class="machine-action-row">
            <.link
              :if={@editor_control == :available}
              id="open-vscode"
              href={~p"/machines/#{@vm.id}/code"}
              target="_blank"
              rel="noopener noreferrer"
              class="console-button machine-editor-button"
            >
              Open VS Code <.glyph name="arrow_up_right" />
            </.link>
            <button
              :if={@editor_control not in [:available, :hidden]}
              id="open-vscode-disabled"
              type="button"
              disabled
              aria-describedby="vscode-unavailable"
              class="console-button machine-editor-button"
            >
              Open VS Code
            </button>
            <div
              :if={@vm.permissions.manage && @vm.desired_state != :deleted}
              id="lifecycle-actions"
              class="row"
            >
              <Layouts.action
                :if={@vm.desired_state != :running || @vm.observed_state == :failed}
                id="start-machine"
                tone="primary"
                phx-click="machine-power"
                phx-value-kind="start"
                phx-value-key={@power_key}
              >
                Start machine
              </Layouts.action>
              <Layouts.action
                :if={@vm.desired_state == :running}
                id="stop-machine"
                tone="default"
                phx-click="machine-power"
                phx-value-kind="stop"
                phx-value-key={@power_key}
              >
                Stop
              </Layouts.action>
            </div>
          </div>
          <%= if @editor_control not in [:available, :hidden] do %>
            <p id="vscode-unavailable" class="machine-editor-notice muted">
              <%= case @editor_control do %>
                <% :unsupported_image -> %>
                  This machine's image does not support the current browser editor.
                  Create a new machine using the current NixOS or Ubuntu image.
                <% :not_running -> %>
                  VS Code requires a running machine.
                <% _ -> %>
                  VS Code is temporarily unavailable for this machine.
              <% end %>
            </p>
          <% end %>
        </div>
      </header>
      <section
        id="machine-connect"
        phx-hook="MachineConnection"
        class="machine-connect"
        aria-labelledby="machine-connect-title"
      >
        <h2 id="machine-connect-title">Connect from your computer</h2>
        <%= if @connection && capability?(@vm, :ssh) do %>
          <h3 class="connection-platform">
            Linux / macOS
            <span class="muted">— installs Overalls, configures SSH, and connects to this machine.</span>
          </h3>
          <div id="ssh-connection-commands" class="connection-command">
            <pre><code id="machine-install-command">{@connection.install}</code></pre>
            <button
              type="button"
              class="console-button primary"
              data-copy-command="machine-install-command"
            >Copy</button>
          </div>
          <div class="connection-secondary">
            <span class="muted">Already installed?</span><code id="machine-ssh-command">{@connection.ssh}</code>
            <button
              type="button"
              class="console-button compact"
              data-copy-command="machine-ssh-command"
              aria-label="Copy SSH command"
            >Copy</button>
          </div>
          <details id="machine-connect-windows">
            <summary>Windows (PowerShell)</summary>
            <p class="muted">
              Installs Overalls for Windows, offers OpenSSH 9.6 or newer through winget
              when the built-in client is older, configures SSH, and connects.
            </p>
            <div class="connection-command">
              <pre><code id="machine-install-command-windows">{@connection.install_windows}</code></pre>
              <button
                type="button"
                class="console-button primary"
                data-copy-command="machine-install-command-windows"
                aria-label="Copy Windows install command"
              >Copy</button>
            </div>
            <div class="connection-secondary">
              <span class="muted">Already installed?</span><code id="machine-ssh-command-windows">{@connection.ssh_windows}</code>
              <button
                type="button"
                class="console-button compact"
                data-copy-command="machine-ssh-command-windows"
                aria-label="Copy Windows SSH command"
              >Copy</button>
            </div>
          </details>
        <% else %>
          <p id="machine-connect-unavailable" class="muted">
            <%= cond do %>
              <% capability?(@vm, :available) && !capability?(@vm, :ssh) -> %>
                This machine's image has no guest agents yet: SSH, the browser terminal
                and agents are unavailable. Use Boot log to view the read-only host console.
              <% !@vm.permissions.write -> %>
                SSH connection requires write access to this machine.
              <% @vm.profile == :inception -> %>
                Use the browser terminal for this Inception environment.
              <% true -> %>
                SSH connection details are temporarily unavailable.
            <% end %>
          </p>
        <% end %>
        <span id="machine-copy-status" role="status" aria-live="polite" phx-update="ignore"></span>
      </section>
      <.machine_nav vm={@vm} active={@active} />
    </div>
    """
  end

  attr(:vm, :map, required: true)
  attr(:id_prefix, :string, required: true)
  attr(:variant, :atom, values: [:button, :link], default: :button)

  # @cc [owner:ghuntley,label:product] machine-editor-action-presentation
  # List editor actions MUST match the adjacent terminal's text-only treatment:
  # console-button in the Machines table, plain link with an arrow in Overview.
  # Unavailable actions MUST remain disabled and retain their explanatory text.
  @spec machine_editor_action(map()) :: Phoenix.LiveView.Rendered.t()
  def machine_editor_action(assigns) do
    assigns = assign(assigns, :editor_control, editor_control(assigns.vm))

    ~H"""
    <.link
      :if={@editor_control == :available}
      id={"#{@id_prefix}-#{@vm.id}-vscode"}
      href={~p"/machines/#{@vm.id}/code"}
      target="_blank"
      rel="noopener noreferrer"
      class={if @variant == :button, do: "console-button", else: "machine-editor-link"}
      aria-label={"Open VS Code for #{@vm.name}"}
    >Open VS Code{if @variant == :link, do: " ↗"}</.link>
    <button
      :if={@editor_control not in [:available, :hidden]}
      id={"#{@id_prefix}-#{@vm.id}-vscode-disabled"}
      type="button"
      disabled
      aria-describedby={"#{@id_prefix}-#{@vm.id}-vscode-reason"}
      class={if @variant == :button, do: "console-button", else: "machine-editor-link"}
    >Open VS Code</button>
    <p
      :if={@editor_control not in [:available, :hidden]}
      id={"#{@id_prefix}-#{@vm.id}-vscode-reason"}
      class="machine-editor-notice muted"
      role="status"
    >
      {editor_unavailable_message(@editor_control)}
    </p>
    """
  end

  # @cc [owner:ghuntley,label:security;product] machine-editor-projection
  # Shared editor actions MUST use the finite projected eligibility state and
  # MUST render links only for available controls. Disabled reasons are
  # presentation feedback; they MUST NOT authorize or imply a launch grant.
  @spec editor_control(map()) ::
          :available | :unsupported_image | :unavailable | :not_running | :hidden
  def editor_control(
        %{
          permissions: %{write: true},
          profile: profile,
          desired_state: desired,
          observed_state: observed
        } = vm
      )
      when desired != :deleted do
    cond do
      not OverallsProtocol.ProfilePolicy.allows?(profile, :editor) -> :hidden
      profile == :customer and not Map.get(vm, :owner, false) -> :hidden
      not capability?(vm, :editor) -> :hidden
      Map.get(vm, :editor_image_status) == :unsupported_image -> :unsupported_image
      Map.get(vm, :editor_image_status) != :available -> :unavailable
      desired != :running or observed != :running -> :not_running
      true -> :available
    end
  end

  def editor_control(_), do: :hidden

  @spec editor_unavailable_message(atom()) :: String.t()
  def editor_unavailable_message(:unsupported_image),
    do: "Create a new machine using the current image to use VS Code."

  def editor_unavailable_message(:not_running), do: "VS Code requires a running machine."
  def editor_unavailable_message(:unavailable), do: "VS Code is temporarily unavailable."
  def editor_unavailable_message(_), do: "VS Code is unavailable for this machine."

  @spec capability?(map(), atom()) :: boolean()
  defp capability?(vm, name) do
    case Map.get(vm, :guest_capabilities) do
      %{} = capabilities -> Map.get(capabilities, name, false) == true
      _ -> false
    end
  end

  @spec workspace_gib(non_neg_integer()) :: String.t()
  defp workspace_gib(bytes), do: :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1)

  @spec profile_name(atom()) :: String.t()
  defp profile_name(:oss), do: "OSS"
  defp profile_name(profile), do: profile |> Atom.to_string() |> String.capitalize()
end
