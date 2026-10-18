defmodule MarshallWeb.AuthController do
  use MarshallWeb, :controller
  use AshAuthentication.Phoenix.Controller
  require Marshall.Events

  # @cc [owner:ghuntley,label:security] magic-link-request-is-not-login
  # A successful link request has no authenticated user. Request callbacks MUST
  # preserve return_to and session authority, skip login/MFA checks and sign-in
  # events, and give identical generic feedback for success and failure.
  @spec success(
          Plug.Conn.t(),
          AshAuthentication.Phoenix.Controller.activity(),
          AshAuthentication.Phoenix.Controller.user(),
          AshAuthentication.Phoenix.Controller.token()
        ) :: Plug.Conn.t()
  def success(conn, {:magic_link, :request}, _user, _token), do: magic_link_requested(conn)

  # @cc [owner:ghuntley,label:security] success-callback-revoked-refusal
  # A login revoked between sign-in commit and this callback MUST be refused
  # without storing a session, with a generic predefined message and no token
  # or failure details; it MUST NOT crash on the absent login.
  def success(conn, activity, user, _token) do
    pending_launch? = not is_nil(MarshallWeb.PendingLaunch.read(get_session(conn)))

    return_to =
      if pending_launch?, do: ~p"/launch", else: get_session(conn, :return_to) || ~p"/overview"

    token = Ash.Resource.get_metadata(user, :token)

    case Marshall.Accounts.Login.verify(token, user) do
      {:ok, jti, _} ->
        if activity == {:magic_link, :sign_in}, do: Marshall.Accounts.Security.primary(user, jti)

        message =
          case activity do
            {:confirm_new_user, :confirm} -> gettext("Your email address has now been confirmed")
            {:password, :reset} -> gettext("Your password has successfully been reset")
            _ -> gettext("You are now signed in")
          end

        Marshall.Events.emit("auth.signed_in", user_id: user.id)

        conn
        |> delete_session(:return_to)
        |> store_in_session(user)
        # If your resource has a different name, update the assign name here (i.e :current_admin)
        |> assign(:current_user, user)
        |> put_flash(:info, message)
        |> redirect(to: return_to)

      :error ->
        Marshall.Events.emit("auth.sign_in_failed", reason: :session_revoked)

        conn
        |> delete_session(:return_to)
        |> put_flash(
          :error,
          gettext("Your sign-in is no longer valid. Request a new sign-in link.")
        )
        |> redirect(to: ~p"/sign-in")
    end
  end

  # @cc [owner:ghuntley,label:security] authentication-public-failure
  # failure/3 MUST render only predefined authentication messages and never
  # include the raw failure term, bearer token or token-bearing request path.
  @spec failure(Plug.Conn.t(), AshAuthentication.Phoenix.Controller.activity(), term()) ::
          Plug.Conn.t()
  def failure(conn, {:magic_link, :request}, _reason), do: magic_link_requested(conn)

  def failure(conn, activity, reason) do
    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          gettext("""
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """)

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          gettext("""
          An account with this email already exists. We've sent a link to that
          address - confirm it to finish linking this provider to your account.
          """)

        _ ->
          gettext("Incorrect email or password")
      end

    Marshall.Events.emit("auth.sign_in_failed", reason: sign_in_failure(activity, reason))

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  @spec magic_link_requested(Plug.Conn.t()) :: Plug.Conn.t()
  defp magic_link_requested(conn) do
    conn
    |> put_flash(:info, MarshallWeb.AuthOverrides.magic_link_request_feedback())
    |> redirect(to: ~p"/sign-in")
  end

  # @cc [owner:ghuntley,label:security;observability] signout-committed-credentials
  # Sign-out MUST revoke supplied remembered and browser credentials under their
  # ordered account locks even without a current login. Its outcome event MUST
  # follow successful commit and MUST NOT contain cookie or token values.
  @spec sign_out(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"
    conn = fetch_cookies(conn)

    # Serialize remembered-token exchange with revoking this browser's cookies.
    {:ok, conn} =
      Marshall.Compute.Ledger.transaction(fn ->
        cookie_names =
          AshAuthentication.Strategy.RememberMe.Plug.Helpers.all_remember_me_cookie_names(
            :marshall
          )

        tokens = for name <- cookie_names, token = conn.cookies[name], is_binary(token), do: token

        users =
          case conn.assigns[:current_user] do
            %Marshall.Accounts.User{id: id} -> [id]
            _ -> []
          end

        Marshall.Accounts.RememberedLogin.lock_credentials!(tokens, users)
        Enum.each(users, &Marshall.Control.Hints.notify_user/1)

        clear_session(conn, :marshall)
      end)

    case conn.assigns[:current_user] do
      %Marshall.Accounts.User{id: id} ->
        Marshall.Events.emit("auth.signed_out", user_id: id)

      _ ->
        Marshall.Events.emit("auth.signed_out", [])
    end

    conn
    |> put_flash(:info, gettext("You are now signed out"))
    |> redirect(to: return_to)
  end

  defp sign_in_failure(_activity, %AshAuthentication.Errors.AuthenticationFailed{
         caused_by: %Ash.Error.Forbidden{
           errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
         }
       }),
       do: :unconfirmed_account

  defp sign_in_failure(_activity, %AshAuthentication.Errors.AuthenticationFailed{
         caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
       }),
       do: :confirmation_required

  defp sign_in_failure(_activity, _reason), do: :invalid_credentials
end
