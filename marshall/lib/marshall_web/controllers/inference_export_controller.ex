defmodule MarshallWeb.InferenceExportController do
  use MarshallWeb, :controller
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    action =
      if conn.path_info == ["admin", "usage", "export"],
        do: :list_usage_for_admin,
        else: :list_usage

    with %Marshall.Accounts.User{} = user <- conn.assigns[:current_user],
         {:ok, _, _} <- Marshall.Accounts.Login.verify(get_session(conn, "user_token"), user),
         {:ok, page} <-
           apply(Marshall.Inference, action, [
             %{filters: Map.take(params, ~w(provider model after))},
             [actor: user]
           ]) do
      lines =
        [
          ~w(request_id vm_id owner_id provider model operation admitted_at outcome completeness input_tokens output_tokens estimated_token_usd pricing_source pricing_version pricing_digest)
        ] ++
          Enum.map(page.rows, fn row ->
            usage = row.completion || %{}
            tokens = usage["tokens"] || %{}

            [
              row.id,
              row.vm_id,
              row.owner_id,
              row.provider,
              row.model,
              row.operation,
              DateTime.to_iso8601(row.inserted_at),
              usage["outcome"],
              usage["completeness"] || "unknown",
              tokens["input_tokens"],
              tokens["output_tokens"],
              get_in(usage, ["cost_estimate", "usd"]),
              get_in(usage, ["cost_estimate", "source"]),
              get_in(usage, ["cost_estimate", "version"]),
              get_in(usage, ["cost_estimate", "digest"])
            ]
          end)

      csv = Enum.map_join(lines, "\r\n", fn row -> Enum.map_join(row, ",", &cell/1) end) <> "\r\n"

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"inference-usage.csv\"")
      |> send_resp(200, csv)
    else
      _ -> send_resp(conn, 404, dgettext("inference", "Unavailable"))
    end
  end

  defp cell(nil), do: ""

  defp cell(value) do
    text = to_string(value)

    text =
      if String.starts_with?(text, ["=", "+", "-", "@", "\t", "\r"]), do: "'" <> text, else: text

    "\"" <> String.replace(text, "\"", "\"\"") <> "\""
  end
end
