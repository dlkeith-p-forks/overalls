defmodule Marshall.Notifications.DeviceActions do
  @moduledoc "Owner-scoped device registration, listing, removal and preference (ADR-0225)."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{AccountLifecycle, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications
  alias Marshall.Notifications.{Device, InstallIdentities}
  alias OverallsProtocol.{SSHCommand, SusanPoke}
  require Ash.Query
  require Marshall.Events

  @limit 10

  @type event ::
          {:registered, Ash.UUID.t(), Ash.UUID.t(), Device.platform()}
          | {:transition, Ash.UUID.t(), Device.state(), atom()}
          | nil

  @doc "The maximum number of live devices per user."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @impl true
  def run(input, options, %{actor: %User{} = actor}) do
    result =
      Ledger.transaction(fn -> perform(options[:operation], input.arguments, actor) end, actor)

    with {:ok, {value, event}} <- result do
      unless Marshall.Repo.in_transaction?(), do: emit(event)
      {:ok, value}
    end
    |> Marshall.SSH.Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security;concurrency] notification-device-registration
  # Registration MUST be refused with push_disabled when the operator disabled
  # notifications, MUST bind the device to the caller's current unarchived SSH
  # key, MUST hold the account admission fence and a per-user lock, and MUST
  # refuse an eleventh live device. Re-registering the same device public key
  # refreshes the live row instead of creating another.
  @spec perform(atom(), map(), User.t()) :: {map(), event()}
  defp perform(:register, arguments, user) do
    unless Notifications.enabled?(), do: Ledger.rollback(:push_disabled)

    enc_public_key =
      with true <- SSHCommand.device_public_key?(arguments.enc_public_key),
           {:ok, raw} <- Base.url_decode64(arguments.enc_public_key, padding: false) do
        raw
      else
        _ -> Ledger.rollback(:invalid_request)
      end

    unless SusanPoke.push_key?(arguments.push_key), do: Ledger.rollback(:invalid_request)
    label = normalize_label(arguments[:label])

    AccountLifecycle.admit!(user.id)
    lock!("user:" <> user.id)

    case Ledger.read!(Marshall.SSH.Key, id: arguments.key_id, user_id: user.id) do
      [_key] -> :ok
      [] -> Ledger.rollback(:unauthorized)
    end

    _identity = InstallIdentities.ensure!()

    attributes = %{
      key_id: arguments.key_id,
      platform: arguments.platform,
      push_key: arguments.push_key,
      push_key_digest: Notifications.digest(arguments.push_key),
      label: label
    }

    live =
      Device
      |> Ash.Query.filter(user_id == ^user.id and state in [:pending, :active])
      |> Ash.Query.lock(:for_update)
      |> Ash.read!(actor: SystemActor.compute())

    case Enum.find(live, &(&1.enc_public_key == enc_public_key)) do
      %Device{} = device ->
        device = Ledger.update!(device, :refresh, attributes)
        {view(device), {:transition, device.id, :active, :refreshed}}

      nil ->
        if length(live) >= @limit, do: Ledger.rollback(:device_limit)

        device =
          Device
          |> Ledger.create!(
            :register,
            Map.merge(attributes, %{user_id: user.id, enc_public_key: enc_public_key})
          )
          |> Ledger.update!(:activate, %{})

        {view(device), {:registered, device.id, user.id, device.platform}}
    end
  end

  defp perform(:list, _arguments, user) do
    items =
      Device
      |> Ash.Query.filter(user_id == ^user.id and state in [:pending, :active, :invalidated])
      |> Ash.Query.sort(inserted_at: :desc, id: :asc)
      |> Ash.Query.limit(50)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(&view/1)

    {%{items: items, limit: @limit, push_enabled: Notifications.enabled?()}, nil}
  end

  # @cc [owner:ghuntley,label:security] notification-device-owner-removal
  # Removal and preference changes MUST verify persisted ownership under a row
  # lock; another account's device MUST refuse as device_not_found. Removing an
  # already revoked device succeeds without another transition.
  defp perform(:remove, %{id: id}, user) do
    case Ledger.lock!(Device, id) do
      %Device{user_id: owner, state: :revoked} = device when owner == user.id ->
        {view(device), nil}

      %Device{user_id: owner} = device when owner == user.id ->
        device =
          Ledger.update!(device, :revoke, %{state_reason: :removed, finished_at: Ledger.now()})

        {view(device), {:transition, device.id, :revoked, :removed}}

      _ ->
        Ledger.rollback(:device_not_found)
    end
  end

  defp perform(:preference, %{id: id, enabled: enabled}, user) do
    case Ledger.lock!(Device, id) do
      %Device{user_id: owner, state: state, enabled: ^enabled} = device
      when owner == user.id and state in [:pending, :active] ->
        {view(device), nil}

      %Device{user_id: owner, state: state} = device
      when owner == user.id and state in [:pending, :active] ->
        device = Ledger.update!(device, :set_preference, %{enabled: enabled})
        reason = if enabled, do: :preference_on, else: :preference_off
        {view(device), {:transition, device.id, device.state, reason}}

      _ ->
        Ledger.rollback(:device_not_found)
    end
  end

  @doc "The public, key-free projection of a device."
  @spec view(Device.t()) :: map()
  def view(device) do
    %{
      id: device.id,
      platform: device.platform,
      label: device.label,
      state: device.state,
      enabled: device.enabled,
      key_id: device.key_id,
      inserted_at: device.inserted_at
    }
  end

  @spec normalize_label(term()) :: String.t() | nil
  defp normalize_label(label) when is_binary(label) do
    case String.trim(label) do
      "" ->
        nil

      trimmed ->
        if String.printable?(trimmed), do: trimmed, else: Ledger.rollback(:invalid_request)
    end
  end

  defp normalize_label(_), do: nil

  @spec emit(event()) :: :ok
  defp emit({:registered, device_id, user_id, platform}),
    do:
      Marshall.Events.emit("notifications.device_registered",
        device_id: device_id,
        user_id: user_id,
        platform: platform
      )

  defp emit({:transition, device_id, state, reason}),
    do:
      Marshall.Events.emit("notifications.device_transition",
        device_id: device_id,
        state: state,
        reason: reason
      )

  defp emit(nil), do: :ok

  defp lock!(value) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["notifications:" <> value],
      log: false
    )
  end
end
