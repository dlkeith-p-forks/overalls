defmodule Marshall.LillySocket do
  @moduledoc """
  Lilly control requests as the control socket serves them (ADR-0142).

  `request/3` authenticates the host credential the way the upgrade does and
  runs `Marshall.Control.Services.Lilly`. The socket carries only a closed
  error name; the status is that name's class (the one the retired
  `/api/provisioners/v3` routes answered), so tests keep asserting classes.
  """
  import ExUnit.Assertions

  alias Marshall.Control.Services.Lilly

  @type reply :: {pos_integer(), map()}

  @conflicts ~w(stale_connection stale_console_request stale_report reconciliation_required outcome_conflict)

  @doc "Sends one `lilly.<action>` request with JSON-shaped payload keys."
  @spec request(binary(), String.t(), map()) :: reply()
  def request(token, action, payload) do
    # Like the socket, run in a request process with authentication redaction.
    Task.async(fn ->
      Logger.metadata(marshall_authentication: true)
      body = payload |> JSON.encode!() |> JSON.decode!()

      with {:ok, principal} <- Lilly.authenticate(token),
           {:ok, value} <- Lilly.handle_request("lilly." <> action, body, principal) do
        {200, value}
      else
        :refused -> {401, %{"error" => "unauthorized"}}
        :unavailable -> {503, %{"error" => "temporarily_unavailable"}}
        {:error, name} -> {class(name), %{"error" => name}}
      end
    end)
    |> Task.await(15_000)
  end

  @doc "Asserts the reply's status class and returns its document."
  @spec reply(reply(), pos_integer()) :: map()
  def reply({status, body}, expected) do
    assert status == expected, "expected #{expected}, got #{status}: #{inspect(body)}"
    body
  end

  @spec class(String.t()) :: pos_integer()
  defp class("unauthorized"), do: 401
  defp class("machine_identity_mismatch"), do: 403
  defp class("unsupported_version"), do: 426
  defp class("temporarily_unavailable"), do: 503
  defp class(name) when name in @conflicts, do: 409
  defp class(_name), do: 400
end
