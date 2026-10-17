defmodule Marshall.AudiSocket do
  @moduledoc """
  Audi gateway and DNS requests as the control socket serves them (ADR-0142).

  `request/3` authenticates the credential the way the upgrade does and runs
  `Marshall.Control.Services.Audi`. The socket carries only a closed error
  name; the status is that name's class (the one its former HTTPS route
  answered), so tests keep asserting refusal classes.
  """
  import ExUnit.Assertions

  alias Marshall.Control.Services.Audi

  @type reply :: {pos_integer(), map()}

  @classes %{
    "invalid_request" => 400,
    "unauthorized" => 401,
    "authentication_required" => 401,
    "forbidden" => 403,
    "host_key_conflict" => 409,
    "message_too_large" => 413,
    "unsupported_version" => 426,
    "capacity" => 429,
    "session_limit" => 429,
    "unavailable" => 503
  }

  @doc "Sends one `audi.<route>` request with JSON-shaped payload keys."
  @spec request(binary(), String.t(), map()) :: reply()
  def request(token, route, payload) do
    # Like the socket, run in a request process with authentication redaction.
    Task.async(fn ->
      Logger.metadata(marshall_authentication: true)
      body = payload |> Jason.encode!() |> Jason.decode!()

      with {:ok, principal} <- Audi.authenticate(token),
           {:ok, value} <-
             Audi.handle_request("audi." <> String.replace(route, "-", "_"), body, principal) do
        {200, value}
      else
        :refused -> {401, %{"error" => "unauthorized"}}
        {:error, name} -> {Map.fetch!(@classes, name), %{"error" => name}}
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
end
