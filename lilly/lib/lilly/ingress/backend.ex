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
