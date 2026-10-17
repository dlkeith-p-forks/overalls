defmodule MarshallWeb.SSHApprovalLogin do
  @moduledoc "Preserve a bounded SSH approval destination across email sign-in."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] ssh-approval-return-path
  # Only a validated token in this fixed local route MAY enter return_to. GET
  # MUST NOT consume the approval, and no user-provided redirect may be followed.
  @impl true
  def call(%{path_params: %{"token" => token}} = conn, _) do
    case Marshall.SSH.Token.digest(token, :approval) do
      {:ok, _} ->
        if conn.assigns[:current_user] do
          conn
        else
          conn
          |> put_session(:return_to, "/ssh/approve/" <> token)
          |> Phoenix.Controller.redirect(to: "/sign-in")
          |> halt()
        end

      :error ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end
end
