defmodule MarshallWeb.SignOutOverrides do
  @moduledoc "Runtime copy overrides for the library's CSRF-protected sign-out confirmation."
  use Gettext, backend: MarshallWeb.Gettext

  alias AshAuthentication.Phoenix.Components.SignOut

  # @cc [owner:ghuntley,label:product;security] sign-out-presentation-only
  # These overrides MUST translate only the existing sign-out heading, guidance
  # and submit label. The authentication library MUST retain ownership of the
  # DELETE action, form method and CSRF protection; rendering MUST NOT revoke a
  # login or accept a client-selected account identity.
  @spec overrides() :: %{{module(), atom()} => String.t()}
  def overrides do
    %{
      {SignOut, :h2_text} => dgettext("auth", "Sign out"),
      {SignOut, :info_text} => dgettext("auth", "Are you sure you want to sign out?"),
      {SignOut, :button_text} => dgettext("auth", "Sign out")
    }
  end

  # AuthenticationPrivacy establishes the browser locale before the library's
  # mount hooks. Reapply it after those hooks have restored the current user so
  # an account override also applies to the connected confirmation component.
  @spec on_mount(:locale, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:locale, _params, session, socket),
    do: {:cont, Marshall.Localization.assign_socket(socket, session)}
end
