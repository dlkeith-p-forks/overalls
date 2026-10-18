defmodule MarshallWeb.Layouts do
  @moduledoc """
  Application shell for the Monospace Web presentation (ADR-0161): a sidebar
  of navigation trees beside the main column, a drawer on narrow screens, and
  a header table on public pages.
  """
  use MarshallWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"
  )

  attr(:compute, :boolean, default: false)
  attr(:active, :string, default: "machines")
  attr(:admin_active, :string, default: "nodes")

  attr(:time_zone, :string,
    default: nil,
    doc: "the viewer's resolved IANA zone; nil hides the account clock"
  )

  attr(:now, :any, default: nil, doc: "the current UTC DateTime for the account clock")

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <div class="workspace-shell">
      <.console_header
        current_scope={@current_scope}
        active={@active}
        admin_active={@admin_active}
        time_zone={@time_zone}
        now={@now}
      />
      <div class="workspace-body">
        <main
          id="main-content"
          class={[
            "console-main",
            !@compute && "console-narrow",
            @active == "admin" && "console-admin"
          ]}
        >
          <nav
            :if={@active != "overview"}
            class="workspace-breadcrumb"
            aria-label={gettext("Breadcrumb")}
          >
            <.link navigate={~p"/overview"}>{gettext("Home")}</.link><span aria-hidden="true">/</span>
            <span>{section_title(@active, @admin_active)}</span>
          </nav>
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.admin_elevation_modal :if={@current_scope} />
    <.flash_group flash={@flash} />
    """
  end

  defp admin_elevation_modal(assigns) do
    ~H"""
    <div id="admin-elevation-hook" phx-hook="AdminElevation" phx-update="ignore">
      <dialog
        id="admin-elevation-modal"
        aria-labelledby="admin-elevation-title"
        aria-describedby="admin-elevation-description"
      >
        <div class="row between">
          <h2 id="admin-elevation-title">{gettext("Confirm administrative change")}</h2>
          <button
            type="button"
            data-admin-elevation-cancel
            aria-label={gettext("Cancel verification")}
            class="console-button ghost"
          >×</button>
        </div>
        <p id="admin-elevation-description" class="muted">
          {gettext(
            "This change needs a fresh passkey verification. Your verification lasts 15 minutes."
          )}
        </p>
        <p id="admin-elevation-status" aria-live="polite" role="status"></p>
        <div class="dialog-actions">
          <button id="admin-elevation-verify" type="button" class="console-button primary">
            {gettext("Verify with passkey")}
          </button>
          <button
            id="admin-elevation-cancel"
            type="button"
            data-admin-elevation-cancel
            class="console-button ghost"
          >{gettext("Cancel")}</button>
        </div>
      </dialog>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")} <.glyph name="refresh" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")} <.glyph name="refresh" />
      </.flash>
    </div>
    """
  end

  attr(:current_scope, :map, default: nil)
  attr(:active, :string, default: nil)
  attr(:admin_active, :string, default: "nodes")
  attr(:time_zone, :string, default: nil)
  attr(:now, :any, default: nil)

  # @cc [owner:ghuntley,label:product] signed-in-account-navigation
  # The "Your account" tree MUST open with one Account entry (#nav-account,
  # /settings) that covers profile, sign-in passkeys and SSH keys, followed by
  # AI usage (#nav-usage, /usage); the account menu MUST show the viewer's local
  # clock under the email, linking to /settings#profile, whenever a zone and
  # instant are given. There MUST be no separate Profile, Security or SSH keys
  # navigation entries.

  # @cc [owner:ghuntley,label:product] signed-in-control-room-navigation
  # Every signed-in account MUST see the Control room mode switch regardless of
  # administrator membership. Public navigation MUST still require sign-in.

  # @cc [owner:ghuntley,label:product] signed-in-hldd-reference-navigation
  # The shared signed-in menu MUST place HLDD immediately below Field notes,
  # using the same link styling and a Reference hint.

  # @cc [owner:ghuntley,label:product] signed-in-source-code-navigation
  # The shared signed-in menu MUST place Source code immediately below HLDD,
  # linking to https://github.com/ghuntley/overalls with ordinary navigation.

  # @cc [owner:ghuntley,label:product] browser-extension-guide-navigation
  # The public header and shared signed-in menu MUST expose a browser extension
  # link to /docs/browser-extension with ordinary navigation. The setup links
  # remain presentation hints and cannot grant access or change authorization.
  @spec console_header(map()) :: Phoenix.LiveView.Rendered.t()
  def console_header(assigns) do
    assigns = assign(assigns, :groups, navigation(assigns.active))

    ~H"""
    <a href="#main-content" class="skip-link">{gettext("Skip to content")}</a>
    <header :if={!@current_scope} class="public-header">
      <table class="header">
        <tr>
          <td colspan="2" rowspan="2" class="width-auto">
            <p class="title"><.link href={~p"/"} class="console-brand">Overalls</.link></p>
          </td>
          <th>{gettext("Docs")}</th>
          <td class="width-min"><.link href={~p"/docs"}>{gettext("Field notes")}</.link></td>
        </tr>
        <tr>
          <th>{gettext("Source")}</th>
          <td class="width-min">
            <a href="https://github.com/ghuntley/overalls">GitHub <span aria-hidden="true">↗</span></a>
          </td>
        </tr>
        <tr data-overalls-extension-setup="true">
          <th>{gettext("Browser")}</th>
          <td class="width-min">
            <.link id="public-marvin-extension" href={~p"/docs/browser-extension"}>
              {gettext("Browser extension")} <span aria-hidden="true">↗</span>
            </.link>
          </td>
        </tr>
        <tr>
          <th class="width-min">{gettext("Account")}</th>
          <td class="width-auto">
            <.link href={~p"/sign-in"} class="console-button primary">{gettext("Sign in")}</.link>
          </td>
          <th class="width-min">{gettext("Appearance")}</th>
          <td class="width-min"><.theme_toggle /></td>
        </tr>
      </table>
    </header>
    <div :if={@current_scope} id="workspace-navigation" phx-hook="WorkspaceNavigation">
      <header class="mobile-header">
        <.link navigate={~p"/overview"} class="console-brand">Overalls<span class="brand-dot">.</span></.link>
        <button
          id="navigation-open"
          class="console-button ghost"
          type="button"
          aria-controls="workspace-sidebar"
          aria-expanded="false"
        ><.glyph name="menu" /> {gettext("Menu")}</button>
      </header>
      <button
        id="navigation-backdrop"
        class="navigation-backdrop"
        aria-label={gettext("Close navigation")}
        hidden
      ></button>
      <aside
        id="workspace-sidebar"
        class="workspace-sidebar"
        aria-label={gettext("Workspace navigation")}
      >
        <div class="sidebar-brand">
          <.link navigate={~p"/overview"} class="console-brand">Overalls<span class="brand-dot">.</span></.link>
          <button
            id="navigation-close"
            type="button"
            class="mobile-only console-button ghost"
            aria-label={gettext("Close navigation")}
          >×</button>
        </div>
        <p class="brand-caption">{gettext("Made to get dirty")}</p>
        <nav class="workspace-switch" aria-label={gettext("Workspace mode")}>
          <.link navigate={~p"/overview"} aria-current={@active != "admin" && "true"}>{gettext(
            "Workspace"
          )}</.link>
          <.link navigate={~p"/admin/nodes"} aria-current={@active == "admin" && "true"}>{gettext(
            "Control room"
          )}</.link>
        </nav>
        <nav
          class="sidebar-links"
          aria-label={if @active == "admin", do: gettext("Administration"), else: gettext("Main")}
        >
          <section :for={{title, links} <- @groups}>
            <ul class="tree">
              <li>
                <h2>{title}</h2>
                <ul>
                  <li :for={{key, label, path} <- links}>
                    <.link
                      id={key == "threads" && "nav-threads"}
                      navigate={path}
                      aria-current={
                        if(@active == "admin", do: @admin_active == key, else: @active == key) &&
                          "page"
                      }
                    >{label}</.link>
                  </li>
                </ul>
              </li>
            </ul>
          </section>
          <section>
            <ul class="tree">
              <li>
                <h2>{gettext("Your account")}</h2>
                <ul>
                  <li>
                    <.link
                      id="nav-settings"
                      navigate={~p"/settings"}
                      aria-current={@active == "settings" && "page"}
                    >Settings</.link>
                  </li>
                  <li>
                    <.link
                      navigate={~p"/settings/security"}
                      aria-current={@active == "security" && "page"}
                    >
                      {gettext("Account")}
                    </.link>
                  </li>
                  <li>
                    <.link
                      id="nav-usage"
                      navigate={~p"/usage"}
                      aria-current={@active == "usage" && "page"}
                    >
                      {gettext("AI usage")}
                    </.link>
                  </li>
                  <li data-overalls-extension-setup="true">
                    <.link id="nav-marvin-extension" href={~p"/docs/browser-extension"}>
                      {gettext("Browser extension")}
                    </.link>
                  </li>
                  <li>
                    <.link href={~p"/docs"}>{gettext("Field notes")}
                    <span class="nav-hint">{gettext("Docs ↗")}</span></.link>
                  </li>
                  <li>
                    <.link
                      id="nav-hldd"
                      navigate={~p"/hldd"}
                      aria-current={@active == "hldd" && "page"}
                    >
                      {gettext("HLDD")} <span class="nav-hint">{gettext("Reference")}</span>
                    </.link><.link id="nav-source-code" href="https://github.com/ghuntley/overalls">
                      {gettext("Source code")} <span class="nav-hint">{gettext("GitHub ↗")}</span>
                    </.link>
                  </li>
                </ul>
              </li>
            </ul>
          </section>
        </nav>
        <div class="sidebar-bottom">
          <div class="sidebar-appearance">
            <span>{gettext("Make yourself comfy")}</span><.theme_toggle />
          </div>
          <details class="account-menu">
            <summary>{@current_scope.user.email}</summary>
            <p>{@current_scope.user.email}</p>
            <p :if={@time_zone && @now} class="account-clock">
              <.local_clock id="account-local-clock" zone={@time_zone} now={@now} />
              <.link navigate={~p"/settings#profile"} class="nav-hint">{gettext("Time zone")}</.link>
            </p>
            <.link href={~p"/sign-out"}>{gettext("Sign out")}</.link>
          </details>
        </div>
      </aside>
    </div>
    """
  end

  @spec navigation(String.t() | nil) :: [{String.t(), [{String.t(), String.t(), String.t()}]}]
  defp navigation("admin") do
    [
      {gettext("Accounting"), [{"usage", gettext("Fleet AI usage"), "/admin/usage"}]},
      {gettext("Operations"),
       [
         {"nodes", gettext("Node maintenance"), "/admin/nodes"},
         {"workloads", gettext("Workloads"), "/admin/workloads"},
         {"jobs", gettext("Jobs"), "/admin/jobs"},
         {"operations", gettext("Platform status"), "/admin/operations"}
       ]},
      {gettext("Administration"),
       [
         {"users", gettext("Users"), "/admin/users"},
         {"access", gettext("Access authority"), "/admin/access"},
         {"git", gettext("Git mirrors"), "/admin/git"},
         {"audit", gettext("Audit"), "/admin/audit"}
       ]}
    ]
  end

  defp navigation(_) do
    [
      {gettext("Your workspace"),
       [
         {"overview", gettext("Overview"), "/overview"},
         {"threads", gettext("Threads"), "/threads"},
         {"machines", gettext("Machines"), "/machines"},
         {"integrations", gettext("Integrations"), "/integrations"},
         {"git", gettext("Git repositories"), "/git"},
         {"teams", gettext("Teams"), "/teams"}
       ]}
    ]
  end

  @spec section_title(String.t(), String.t()) :: String.t()
  defp section_title("admin", "usage"), do: gettext("Control room · AI usage")

  defp section_title("admin", key),
    do: gettext("Control room · %{section}", section: section_name(key))

  defp section_title("usage", _), do: gettext("AI usage")
  defp section_title(key, _), do: section_name(key)

  @spec section_name(String.t()) :: String.t()
  defp section_name(key) do
    %{
      "account" => gettext("Account"),
      "overview" => gettext("Overview"),
      "threads" => gettext("Threads"),
      "machines" => gettext("Machines"),
      "integrations" => gettext("Integrations"),
      "git" => gettext("Git repositories"),
      "teams" => gettext("Teams"),
      "nodes" => gettext("Node maintenance"),
      "workloads" => gettext("Workloads"),
      "jobs" => gettext("Jobs"),
      "operations" => gettext("Platform status"),
      "users" => gettext("Users"),
      "access" => gettext("Access authority"),
      "audit" => gettext("Audit")
    }[key] || gettext("Workspace")
  end

  @doc """
  Renders an action as a button, or as a link when `href`, `navigate` or
  `patch` is given. Tones: default, primary (inverse video), danger, ghost.
  """
  attr(:class, :any, default: nil)
  attr(:tone, :string, default: "default", values: ~w(default primary danger ghost))

  attr(:rest, :global,
    include: ~w(disabled type name value href navigate patch method download target rel)
  )

  slot(:inner_block, required: true)

  def action(%{rest: rest} = assigns) do
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={["console-button", @tone, @class]} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={["console-button", @tone, @class]} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  attr(:id, :string, default: nil)
  attr(:state, :string, default: nil)
  attr(:tone, :string, default: nil, values: [nil, "success", "warning", "danger", "muted"])
  slot(:inner_block, required: true)

  def status(assigns) do
    ~H"""
    <span id={@id} class="status-label" data-state={@state} data-tone={@tone}>{render_slot(
      @inner_block
    )}</span>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <label class="appearance-control select">
      <span class="sr-only">{gettext("Appearance")}</span>
      <select data-appearance aria-label={gettext("Appearance")}>
        <option value="system">{gettext("System")}</option>
        <option value="light">{gettext("Light")}</option>
        <option value="dark">{gettext("Dark")}</option>
      </select>
    </label>
    """
  end
end
