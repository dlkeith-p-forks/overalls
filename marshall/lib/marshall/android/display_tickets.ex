defmodule Marshall.Android.DisplayTickets do
  @moduledoc "Machine-scoped, short-lived tickets for the Android display relay."

  @salt "android-display-v1"
  @max_age 30

  @type mode :: :viewer | :controller
  @type claim :: %{
          required(:machine_id) => String.t(),
          required(:actor_id) => String.t(),
          required(:mode) => mode(),
          required(:issued_at) => integer(),
          required(:generation) => pos_integer()
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
         true <- Marshall.Access.Authorization.allowed?(vm, actor, authorization_action(mode)),
         generation when is_integer(generation) and generation > 0 <- generation(vm) do
      claim = %{
        machine_id: vm_id(vm),
        actor_id: actor_id(actor),
        mode: mode,
        issued_at: System.system_time(:second),
        generation: generation
      }

      {:ok, Phoenix.Token.sign(MarshallWeb.Endpoint, @salt, claim)}
    else
      _ -> {:error, :forbidden}
    end
  end

  @spec verify(String.t()) :: {:ok, claim()} | {:error, :invalid_ticket}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(MarshallWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok,
       %{
         machine_id: machine_id,
         actor_id: actor_id,
         mode: mode,
         issued_at: issued_at,
         generation: generation
       } = claim}
      when is_binary(machine_id) and is_binary(actor_id) and mode in [:viewer, :controller] and
             is_integer(issued_at) and is_integer(generation) and generation > 0 ->
        {:ok, claim}

      _ ->
        {:error, :invalid_ticket}
    end
  end

  def verify(_), do: {:error, :invalid_ticket}

  @doc "Checks the immutable machine, generation and mode carried by a ticket."
  @spec claim_matches?(claim(), String.t(), pos_integer(), mode()) :: boolean()
  def claim_matches?(
        %{machine_id: machine_id, generation: ticket_generation, mode: ticket_mode},
        machine_id,
        generation,
        ticket_mode
      )
      when is_binary(machine_id) and is_integer(generation) and generation > 0,
      do: ticket_generation == generation

  def claim_matches?(_, _, _, _), do: false

  @doc "Revalidates the ticket against the current machine generation and image."
  @spec current?(claim(), Marshall.Accounts.User.t()) :: boolean()
  def current?(%{machine_id: machine_id, generation: generation}, actor)
      when is_binary(machine_id) and is_integer(generation) and generation > 0 do
    with {:ok, vm} <- Marshall.Compute.get_vm(%{vm_id: machine_id}, actor: actor),
         true <- android_display?(vm),
         true <- generation(vm) == generation do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def current?(_, _), do: false

  defp android_display?(%{image_id: image_id}) when is_binary(image_id) do
    match?(%{android_display: true}, Marshall.Compute.Images.guest_capabilities(image_id))
  end

  defp android_display?(_), do: false
  defp authorization_action(:viewer), do: "read"
  defp authorization_action(:controller), do: "write"
  defp vm_id(%{id: id}), do: id
  defp vm_id(_), do: nil
  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil

  defp generation(vm), do: Map.get(vm, :generation) || Map.get(vm, :execution_epoch) || 1
end
