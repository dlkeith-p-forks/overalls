defmodule Marshall.PorscheSocket do
  @moduledoc """
  Porsche gateway requests as the control socket serves them (ADR-0142).

  `request/3` authenticates the gateway credential the way the upgrade does,
  then runs the request through `Marshall.SSH.ControlRequests`, the module
  `Marshall.Control.Services.Porsche` wraps. The status is the class the
  socket's request telemetry reports for that answer (200, 4xx or 503), so
  tests keep asserting refusal classes without the deleted HTTPS routes; the
  socket itself carries only the closed name.
  """
  import ExUnit.Assertions

  alias Marshall.Control.Services.Porsche
  alias Marshall.SSH.ControlRequests

  @type reply :: {pos_integer(), map()}

  @doc "Sends one `porsche.<route>` request with JSON-shaped payload keys."
  @spec request(binary(), String.t(), map()) :: reply()
  def request(token, route, payload) do
    # Like the socket, run in a request process with authentication redaction.
    Task.async(fn ->
      Logger.metadata(marshall_authentication: true)
      body = payload |> Jason.encode!() |> Jason.decode!()

      with {:ok, _principal} <- Porsche.authenticate(token),
           {:ok, value} <-
             route |> ControlRequests.handle(token, body) |> ControlRequests.classify() do
        {200, value |> Jason.encode!() |> Jason.decode!()}
      else
        :refused -> {401, %{"error" => "unauthorized"}}
        {:error, status, name} -> {status, %{"error" => name}}
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
