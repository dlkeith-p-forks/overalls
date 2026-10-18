defmodule Marshall.Control.Services.Peach do
  @behaviour Marshall.Control.Service
  @impl true
  def authenticate(token) when is_binary(token) and byte_size(token) == 80 do
    case Marshall.Galileo.Credentials.authenticate(token) do
      {:ok, %{host_id: host_id}} -> {:ok, %{token: token, host_id: host_id}}
      _ -> :refused
    end
  end

  def authenticate(_), do: :refused
  @impl true
  def bind(%{host_id: host_id} = principal, %{"host_id" => host_id} = bind)
      when map_size(bind) == 1, do: {:ok, principal, []}

  def bind(_, _), do: {:close, :refused}
  @impl true
  def handle_request("peach.snapshot", %{"version" => 1, "binding" => binding} = body, %{
        host_id: host_id
      })
      when map_size(body) == 2 do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(binding),
         true <- binding.host_id == host_id,
         {:ok, snapshot} <-
           Marshall.Reflection.Snapshots.fetch(
             Map.new(binding, fn {k, v} -> {Atom.to_string(k), v} end)
           ) do
      {:ok, snapshot}
    else
      _ -> {:error, "invalid_request"}
    end
  end

  def handle_request(_, _, _), do: {:error, "invalid_request"}
end
