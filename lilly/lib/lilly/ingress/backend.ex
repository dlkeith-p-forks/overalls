defmodule Lilly.Ingress.Backend do
  @moduledoc "Local execution admission before a trusted executor opens the guest socket."
  alias Lilly.Ingress.Guardian

  # @cc [owner:ghuntley,label:security] ingress-backend-derived-executor
  # Backend selection and context MUST come only from the current local actor.
  # No socket may open before guardian admission. Missing executor capability,
  # failed connection or lost guardian MUST deny and release temporary resources.
  @spec open({module(), term()}, map()) ::
          {:ok, :gen_tcp.socket(), pid()} | {:error, :ingress_unavailable}
  def open(resolver, binding) do
    with {:ok, guardian, {{executor, context}, command}} <- Guardian.start(resolver, binding) do
      result = connect(executor, context, command, binding)

      case result do
        {:ok, socket} ->
          if Process.alive?(guardian) do
            {:ok, socket, guardian}
          else
            :gen_tcp.close(socket)
            {:error, :ingress_unavailable}
          end

        _ ->
          Process.exit(guardian, :kill)
          {:error, :ingress_unavailable}
      end
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] ingress-backend-detached-bridge
  # bridge/5 MUST admit through the guardian exactly as open/2 before any
  # socket opens. A detachable binding whose executor can bridge detached
  # (ADR-0187) is handed to hostd with Audi's connection and returns
  # {:bridged, guardian}; any other binding falls back to open/2's socket and
  # returns {:socket, socket, guardian}. Every failure kills the guardian
  # and is :ingress_unavailable.
  @spec bridge({module(), term()}, map(), :gen_tcp.socket(), binary(), binary()) ::
          {:bridged, pid()} | {:socket, :gen_tcp.socket(), pid()} | {:error, :ingress_unavailable}
  def bridge(resolver, binding, client, key, greeting) do
    with {:ok, guardian, {{executor, context}, command}} <- Guardian.start(resolver, binding) do
      result =
        if detached?(executor, binding),
          do: detach(executor, context, command, binding, {client, key, greeting}),
          else: connect(executor, context, command, binding)

      case result do
        :ok ->
          {:bridged, guardian}

        {:ok, socket} ->
          if Process.alive?(guardian) do
            {:socket, socket, guardian}
          else
            :gen_tcp.close(socket)
            {:error, :ingress_unavailable}
          end

        _ ->
          Process.exit(guardian, :kill)
          {:error, :ingress_unavailable}
      end
    end
  end

  @doc "A fresh guardian for a bridge's keeper; the keeper is its owner."
  @spec guard({module(), term()}, map()) :: {:ok, pid()} | {:error, :ingress_unavailable}
  def guard(resolver, binding) do
    case Guardian.start(resolver, binding) do
      {:ok, guardian, _authority} -> {:ok, guardian}
      _ -> {:error, :ingress_unavailable}
    end
  end

  defp detached?(executor, binding),
    do:
      Lilly.Network.Ingress.detachable?(binding) and Code.ensure_loaded?(executor) and
        function_exported?(executor, :bridge_ingress, 6)

  defp detach(executor, context, command, binding, {client, key, greeting}) do
    executor.bridge_ingress(context, command, binding, client, key, greeting)
  rescue
    _ -> {:error, :ingress_unavailable}
  catch
    _, _ -> {:error, :ingress_unavailable}
  end

  defp connect(executor, context, command, binding) do
    if function_exported?(executor, :open_ingress, 3),
      do: executor.open_ingress(context, command, binding),
      else: {:error, :ingress_unavailable}
  rescue
    _ -> {:error, :ingress_unavailable}
  catch
    _, _ -> {:error, :ingress_unavailable}
  end
end
