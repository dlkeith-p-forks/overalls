defmodule Marshall.Notifications do
  @moduledoc """
  Content-free push notifications for Mila devices (ADR-0225).

  Devices register over Porsche, deliveries are produced after the outer
  commit of agent question and plan proposal transactions, and
  `Marshall.Notifications.DeliveryWorker` sends end-to-end encrypted pokes to
  Susan (ADR-0224) with bounded retries. `services.marshall.notifications.enable`
  (`MARSHALL_NOTIFICATIONS_ENABLED`) turns registration into a `push_disabled`
  refusal and the producer into a no-op.
  """
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.{Delivery, Device}
  require Ash.Query
  require Marshall.Events

  paper_trail do
    include_versions? true
  end

  resources do
    resource Device do
      define :register_device, action: :register_for_user
      define :list_devices, action: :list_for_user
      define :remove_device, action: :remove_for_user
      define :set_device_preference, action: :set_preference_for_user
    end

    resource Delivery
    resource Marshall.Notifications.InstallIdentity
  end

  @doc "Whether the operator left push notifications enabled (default true)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:marshall, :notifications_enabled, true) == true

  @doc "A short, non-reversible digest for audit and replay comparison."
  @spec digest(binary()) :: String.t()
  def digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  # @cc [owner:ghuntley,label:security;concurrency] notification-revocation-in-transaction
  # Key revocation and account retirement MUST revoke every live or
  # invalidated device bound to that key or user inside the revoking
  # transaction, so no poke can be sealed for a device whose authority is gone.
  @doc "Revokes devices bound to an SSH key. Call inside the key revocation transaction."
  @spec revoke_for_key!(Ash.UUID.t(), :key_revoked) :: non_neg_integer()
  def revoke_for_key!(key_id, reason \\ :key_revoked) do
    Device
    |> Ash.Query.filter(key_id == ^key_id and state in [:pending, :active, :invalidated])
    |> revoke_all!(reason)
  end

  @doc "Revokes all of a user's devices. Call inside the retirement transaction."
  @spec revoke_for_user!(Ash.UUID.t(), :account_retired) :: non_neg_integer()
  def revoke_for_user!(user_id, reason \\ :account_retired) do
    Device
    |> Ash.Query.filter(user_id == ^user_id and state in [:pending, :active, :invalidated])
    |> revoke_all!(reason)
  end

  @spec revoke_all!(Ash.Query.t(), atom()) :: non_neg_integer()
  defp revoke_all!(query, reason) do
    devices =
      query
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ash.read!(actor: SystemActor.compute())

    now = Ledger.now()

    Enum.each(devices, fn device ->
      Ledger.update!(device, :revoke, %{state_reason: reason, finished_at: now})

      Ledger.after_commit(fn ->
        Marshall.Events.emit("notifications.device_transition",
          device_id: device.id,
          state: :revoked,
          reason: reason
        )
      end)
    end)

    length(devices)
  end
end
