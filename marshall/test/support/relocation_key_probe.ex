defmodule Marshall.RelocationKeyProbe do
  @moduledoc false
  @behaviour Plug

  alias OverallsProtocol.Control.Envelope

  def init(owner), do: owner

  # @cc [owner:ghuntley,label:verification] key-probe-observes-real-response
  # The test probe MUST serve the production control socket and notify only
  # after each Lilly exchange's response leaves it. It MUST NOT replace
  # authentication, database work or response validation, and MUST NOT forward
  # request bodies or credentials to observers.
  def call(conn, owner),
    do:
      MarshallWeb.ControlAPI.call(conn,
        socket: __MODULE__.Socket,
        socket_state: %{probe_owner: owner}
      )

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    alias Marshall.Control.Socket, as: Inner

    @impl true
    def init(state) do
      {:ok, inner} = Inner.init(Map.delete(state, :probe_owner))
      {:ok, %{inner: inner, owner: state.probe_owner, keys: MapSet.new()}}
    end

    @impl true
    def handle_in({text, _options} = frame, state) do
      keys =
        case Envelope.decode(text) do
          {:ok, {:req, %{id: id, op: "lilly." <> _route}}} -> MapSet.put(state.keys, id)
          _ -> state.keys
        end

      wrap(Inner.handle_in(frame, state.inner), %{state | keys: keys})
    end

    @impl true
    def handle_info(message, state), do: wrap(Inner.handle_info(message, state.inner), state)

    @impl true
    def terminate(reason, state), do: Inner.terminate(reason, state.inner)

    defp wrap({:push, {:text, text}, inner} = result, state) do
      case Envelope.decode(text) do
        {:ok, {:res, %{id: id, result: outcome}}} ->
          if MapSet.member?(state.keys, id),
            do: send(state.owner, {:key_exchange_complete, status(outcome)})

          {:push, {:text, text}, %{state | inner: inner, keys: MapSet.delete(state.keys, id)}}

        _ ->
          put_elem(result, 2, %{state | inner: inner})
      end
    end

    defp wrap({:ok, inner}, state), do: {:ok, %{state | inner: inner}}

    defp wrap(result, state) when is_tuple(result),
      do:
        put_elem(result, tuple_size(result) - 1, %{
          state
          | inner: elem(result, tuple_size(result) - 1)
        })

    defp status({:ok, _body}), do: 200
    defp status({:error, name}), do: name
  end
end
