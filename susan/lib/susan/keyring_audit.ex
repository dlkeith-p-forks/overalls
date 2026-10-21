defmodule Susan.KeyringAudit do
  @moduledoc """
  Records a `key_rotated` audit entry when the service boots with an active
  keyring id different from the last one audited, so every sealing-key
  rotation is visible in the trail without storing key material.
  """
  require Susan.Events

  @doc "Refuse listener startup until the active keyring has a durable audit record."
  @spec start_link(Susan.Keyring.t()) :: :ignore | {:error, :audit_unavailable}
  def start_link(keyring) do
    case record(keyring) do
      result when result in [:ok, :unchanged] -> :ignore
      :error -> {:error, :audit_unavailable}
    end
  rescue
    _ -> {:error, :audit_unavailable}
  end

  @spec record(Susan.Keyring.t()) :: :ok | :unchanged | :error
  def record(%Susan.Keyring{active: active}) do
    last =
      case Susan.Repo.query!(
             "SELECT keyring_id FROM audit_entries WHERE action = 'key_rotated' ORDER BY seq DESC LIMIT 1",
             []
           ) do
        %{rows: [[id]]} -> id
        %{rows: []} -> nil
      end

    if last == active do
      :unchanged
    else
      case Susan.Audit.Log.append(:key_rotated, :ok, %{keyring_id: active}) do
        {:ok, _} ->
          Susan.Events.emit("susan.keyring_rotated", keyring_id: active)
          :ok

        :error ->
          :error
      end
    end
  end
end
