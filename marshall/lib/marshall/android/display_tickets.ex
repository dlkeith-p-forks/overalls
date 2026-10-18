defmodule Marshall.Android.DisplayTickets do
  @moduledoc "Machine-scoped, short-lived tickets for the Android display relay."

  @salt "android-display-v1"
  @max_age 30

  @type mode :: :viewer | :controller
  @type claim :: %{
          required(:machine_id) => String.t(),
          required(:actor_id) => String.t(),
          required(:mode) => mode(),
          required(:issued_at) => integer()
        }

  # @cc [owner:ghuntley,label:security] android-display-ticket-fence
  # Display tickets MUST be signed, short-lived, bound to one machine and actor,
  # and issued only for an Android-capable image. The relay remains responsible
  # for generation and controller-lease checks before consuming the claim.
  @spec issue(map(), map(), mode()) :: {:ok, String.t()} | {:error, :forbidden}
  def issue(vm, actor, mode) when mode in [:viewer, :controller] do
    with true <- android_display?(vm),
         true <- is_binary(vm_id(vm)),
         true <- is_binary(actor_id(actor)),
         true <- Marshall.Access.Authorization.allowed?(vm, actor, "read") do
      claim = %{
        machine_id: vm_id(vm),
        actor_id: actor_id(actor),
        mode: mode,
        issued_at: System.system_time(:second)
      }

      {:ok, Phoenix.Token.sign(MarshallWeb.Endpoint, @salt, claim)}
    else
      _ -> {:error, :forbidden}
    end
  end

  @spec verify(String.t()) :: {:ok, claim()} | {:error, :invalid_ticket}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(MarshallWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{machine_id: machine_id, actor_id: actor_id, mode: mode, issued_at: issued_at} = claim}
      when is_binary(machine_id) and is_binary(actor_id) and mode in [:viewer, :controller] and
             is_integer(issued_at) ->
        {:ok, claim}

      _ -> {:error, :invalid_ticket}
    end
  end

  def verify(_), do: {:error, :invalid_ticket}

  defp android_display?(%{image_id: image_id}) when is_binary(image_id) do
    match?(%{android_display: true}, Marshall.Compute.Images.guest_capabilities(image_id))
  end

  defp android_display?(_), do: false
  defp vm_id(%{id: id}), do: id
  defp vm_id(_), do: nil
  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil
end
