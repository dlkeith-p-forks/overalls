defmodule MarshallWeb.ScimOidcController do
  @moduledoc "Browser endpoints for OIDC single sign-on while SCIM owns identity lifecycle."
  use MarshallWeb, :controller

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Marshall.Scim.Oidc

  @flow_key :scim_oidc_flow

  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, _params) do
    case Oidc.begin(callback_url()) do
      {:ok, url, flow} ->
        conn
        |> put_session(@flow_key, flow)
        |> redirect(external: url)

      {:error, _reason} ->
        conn
        |> delete_session(@flow_key)
        |> put_flash(:error, dgettext("auth", "Single sign-on is not configured."))
        |> redirect(to: ~p"/sign-in")
    end
  end

  # @cc [owner:ghuntley,label:security] scim-oidc-callback-one-shot
  # The callback MUST remove the session flow before any outcome so a state,
  # nonce or verifier cannot be replayed, and failures MUST render one generic
  # message without provider error text, codes, tokens or claims.
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    flow = get_session(conn, @flow_key)
    conn = delete_session(conn, @flow_key)

    case Oidc.complete(flow, params, callback_url()) do
      {:ok, user, token} ->
        user =
          Ash.Resource.put_metadata(user, :token, token)
          |> Ash.Resource.put_metadata(:authentication_strategies, [:oidc])

        conn
        |> delete_session(:return_to)
        |> store_in_session(user)
        |> assign(:current_user, user)
        |> put_flash(:info, dgettext("auth", "You are now signed in"))
        |> redirect(to: ~p"/overview")

      {:error, _reason} ->
        conn
        |> put_flash(:error, dgettext("auth", "Single sign-on could not authenticate you."))
        |> redirect(to: ~p"/sign-in")
    end
  end

  @spec callback_url() :: String.t()
  defp callback_url, do: url(~p"/auth/oidc/callback")
end
