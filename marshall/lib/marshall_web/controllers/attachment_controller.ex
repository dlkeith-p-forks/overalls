defmodule MarshallWeb.AttachmentController do
  use MarshallWeb, :controller

  @spec upload(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upload(conn, params) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with %Marshall.Accounts.User{} = user <- conn.assigns[:current_user],
         {:ok, _, _} <- Marshall.Accounts.Login.verify(get_session(conn, "user_token"), user),
         {:ok, thread_id} <- Ecto.UUID.cast(params["thread_id"]),
         %Plug.Upload{path: path} <- params["file"],
         {:ok, %{size: size}} when size <= 10 * 1024 * 1024 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, metadata} <-
           Marshall.Agents.AttachmentTransfers.upload(
             user.id,
             thread_id,
             params["idempotency_key"],
             bytes
           ) do
      conn |> put_status(201) |> json(metadata)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # @cc [owner:ghuntley,label:security] attachment-http-current-login
  # Download bytes MUST require a current persisted browser login, a valid UUID,
  # and a single token supplied in a header, never a token-bearing URL.
  # AttachmentTool MUST recheck current thread authority before releasing bytes.
  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => id}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, id} <- Ecto.UUID.cast(id),
         %Marshall.Accounts.User{} = user <- conn.assigns[:current_user],
         {:ok, _, _} <- Marshall.Accounts.Login.verify(get_session(conn, "user_token"), user),
         [token] when byte_size(token) == 43 <- get_req_header(conn, "x-attachment-token"),
         {:ok, bytes} <- Marshall.Agents.AttachmentTool.resolve_download(user.id, id, token) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", "attachment; filename=\"attachment.bin\"")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
