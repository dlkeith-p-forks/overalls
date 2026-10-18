defmodule Marshall.Control.Services.Galileo do
  @moduledoc """
  Galileo over the control WebSocket: identity, authorize and renew.

  The credential is authenticated at upgrade and again by every domain call,
  under the same locks as before, so rotation and revocation take effect on
  the next request exactly as they did over HTTPS.
  """
  @behaviour Marshall.Control.Service

  alias Marshall.Galileo.Authorizations

  @impl true
  def authenticate(token) when is_binary(token) and byte_size(token) == 80 do
    case Authorizations.identity(token) do
      {:ok, %{host_id: host_id}} -> {:ok, %{token: token, host_id: host_id}}
      _ -> :refused
    end
  end

  def authenticate(_token), do: :refused

  # @cc [owner:ghuntley,label:security] control-galileo-bind
  # A Galileo hello MUST carry an empty bind; the identity is the credential's
  # host. Galileo holds no subscriptions until push revocation lands for it.
  @impl true
  def bind(principal, bind) when map_size(bind) == 0, do: {:ok, principal, []}
  def bind(_principal, _bind), do: {:close, :refused}

  @impl true
  def handle_request("galileo.identity", body, %{token: token}) when map_size(body) == 0,
    do: result(Authorizations.identity(token), &%{"host_id" => &1.host_id})

  def handle_request("galileo.authorize", body, %{token: token}),
    do: result(Authorizations.authorize(token, body), & &1)

  def handle_request("galileo.renew", body, %{token: token}),
    do: result(Authorizations.renew(token, body), & &1)

  def handle_request("galileo.github.authorize", body, %{token: token}),
    do: result(Marshall.Galileo.GitHub.authorize(token, body), & &1)

  def handle_request("galileo.github.renew", body, %{token: token}),
    do: result(Marshall.Galileo.GitHub.renew(token, body), & &1)

  def handle_request("galileo.github.close", body, %{token: token}),
    do: result(Marshall.Galileo.GitHub.close(token, body), & &1)

  def handle_request(_op, _body, _identity), do: {:error, "invalid_request"}

  @spec result({:ok, map()} | {:error, term()}, (map() -> map())) ::
          {:ok, map()} | {:error, String.t()}
  defp result({:ok, value}, shape), do: {:ok, stringify(shape.(value))}
  defp result({:error, :unauthorized}, _shape), do: {:error, "unauthorized"}
  defp result({:error, :unavailable}, _shape), do: {:error, "unavailable"}
  defp result({:error, _reason}, _shape), do: {:error, "invalid_request"}

  @spec stringify(map()) :: map()
  defp stringify(map), do: map |> JSON.encode!() |> JSON.decode!()
end
