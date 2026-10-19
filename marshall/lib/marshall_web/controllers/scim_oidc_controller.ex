defmodule MarshallWeb.ScimOidcController do
  use MarshallWeb, :controller

  alias Marshall.Scim.Configuration
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Marshall.Scim.Oidc
  require Ash.Query

  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, _params) do
    with {:ok, config} <- enabled_config(),
         issuer when is_binary(issuer) <- config.oidc_issuer,
         client_id when is_binary(client_id) <- config.oidc_client_id do
      state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      nonce = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      callback = MarshallWeb.Endpoint.url() <> "/auth/oidc/callback"
      authorize = issuer <> "/authorize"

      url =
        URI.append_query(
          URI.parse(authorize),
          URI.encode_query(%{
            "client_id" => client_id,
            "redirect_uri" => callback,
            "response_type" => "code",
            "scope" => "openid email",
            "state" => state,
            "nonce" => nonce
          })
        )

      conn
      |> put_session(:scim_oidc_state, state)
      |> put_session(:scim_oidc_nonce, nonce)
      |> redirect(external: url)
    else
      _ ->
        conn
        |> put_flash(:error, dgettext("auth", "Single sign-on is not configured."))
        |> redirect(to: ~p"/sign-in")
    end
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"state" => state, "iss" => issuer, "sub" => subject} = params) do
    expected = get_session(conn, :scim_oidc_state)
    nonce = get_session(conn, :scim_oidc_nonce)

    if is_binary(expected) and Plug.Crypto.secure_compare(expected, state) and
         (is_nil(params["nonce"]) or params["nonce"] == nonce) do
      claims = %{"iss" => issuer, "sub" => subject}

      case Oidc.sign_in(claims) do
        {:ok, user, token} ->
          user =
            Ash.Resource.set_metadata(user, %{token: token, authentication_strategies: [:oidc]})

          conn
          |> delete_session(:scim_oidc_state)
          |> delete_session(:scim_oidc_nonce)
          |> store_in_session(user)
          |> redirect(to: ~p"/overview")

        _ ->
          failure(conn)
      end
    else
      failure(conn)
    end
  end

  def callback(conn, _), do: failure(conn)

  defp failure(conn) do
    conn
    |> put_flash(:error, dgettext("auth", "Single sign-on could not authenticate you."))
    |> redirect(to: ~p"/sign-in")
  end

  defp enabled_config do
    Configuration
    |> Ash.Query.filter(state == :enabled)
    |> Ash.read_one(actor: Marshall.Authorization.SystemActor.compute())
    |> case do
      {:ok, %Configuration{} = config} -> {:ok, config}
      _ -> {:error, :not_configured}
    end
  end
end
