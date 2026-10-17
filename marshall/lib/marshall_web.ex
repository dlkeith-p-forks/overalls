defmodule MarshallWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use MarshallWeb, :controller
      use MarshallWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # @cc [owner:ghuntley,label:security] static-path-allowlist
  # static_paths/0 MUST expose only public asset roots. Private files, resource
  # snapshots, Cedar policies and release credentials MUST NOT be served by
  # broadening this list to the entire priv directory.
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: MarshallWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: MarshallWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components (Monospace Web presentation, ADR-0161)
      import MarshallWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias MarshallWeb.WorkspaceComponents, as: UI
      alias MarshallWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MarshallWeb.Endpoint,
        router: MarshallWeb.Router,
        statics: MarshallWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
