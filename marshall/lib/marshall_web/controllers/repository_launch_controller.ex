defmodule MarshallWeb.RepositoryLaunchController do
  use MarshallWeb, :controller
  alias MarshallWeb.PendingLaunch

  # @cc [owner:ghuntley,label:security] public-launch-capture-no-admission
  # stage/2 MUST only validate and store bounded launch input in the signed
  # session. The browser CSRF pipeline MUST protect it; it MUST NOT create a VM,
  # invoke domain mutations or accept a caller-supplied expiry or return path.
  @spec stage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stage(conn, params) do
    conn = private_response(conn)

    case PendingLaunch.new(params["source"], params["visit"]) do
      {:ok, pending} ->
        conn
        |> put_session(PendingLaunch.key(), pending)
        |> redirect(to: ~p"/launch")

      {:error, _} ->
        send_resp(
          conn,
          422,
          gettext("This repository link could not be launched. Open the link again.") <> "\n"
        )
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] launch-completion-matched-clear
  # clear/2 MUST require a fresh completed login, a successful-admission receipt
  # bound to that user and current domain permission to read its VM. It MUST
  # clear only the matching staged source/visit, preserve any newer capture, and
  # redirect only to the receipt's same-origin machine path.
  @spec clear(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def clear(conn, params) do
    conn = private_response(conn)

    with %Marshall.Accounts.User{} = user <- conn.assigns[:current_user],
         {:ok, jti, _} <- Marshall.Accounts.Login.verify(get_session(conn, "user_token"), user),
         {:ok, completion} <- PendingLaunch.verify_receipt(params["receipt"]),
         true <- completion.user_id == user.id,
         actor = Marshall.Accounts.Security.bind(user, jti),
         {:ok, %{owner: true}} <-
           Marshall.Compute.get_vm(%{vm_id: completion.vm_id}, actor: actor) do
      conn =
        if PendingLaunch.matches?(get_session(conn), completion),
          do: delete_session(conn, PendingLaunch.key()),
          else: conn

      redirect(conn, to: ~p"/machines/#{completion.vm_id}")
    else
      _ ->
        send_resp(
          conn,
          403,
          gettext("This launch could not be completed. Sign in and open the link again.") <> "\n"
        )
    end
  end

  @spec private_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
