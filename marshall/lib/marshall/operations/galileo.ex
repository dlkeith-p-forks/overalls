defmodule Marshall.Operations.Galileo do
  @moduledoc "Trusted Galileo credential operations; only public metadata leaves the command."
  alias Marshall.Operations.{PrivateFiles, Privacy}
  alias Marshall.Galileo.Credentials
  alias Marshall.Compute.Ledger
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;recovery] galileo-operator-private-custody
  # Rotation MUST exclusively reserve a private output before changing authority
  # and sync the token before transaction commit. Output failures roll back
  # authority. Uncertain replies retain the file for explicit verification;
  # neither credentials nor injected secret values may enter command output.
  @spec rotate(binary(), pos_integer(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def rotate(host, ttl, output) do
    Privacy.run(fn ->
      PrivateFiles.with_new(output, fn file ->
        Ledger.transaction(fn ->
          with {:ok, credential} <- Credentials.rotate(host, ttl),
               :ok <-
                 PrivateFiles.write_sync(file, output, credential.id <> "." <> credential.secret) do
            %{host_id: host, credential_id: credential.id, expires_at: credential.expires_at}
          else
            _ -> Ledger.rollback(:galileo_credential_failed)
          end
        end)
      end)
      |> result(host, :rotated)
    end)
  end

  @spec verify(Path.t()) :: {:ok, map()} | {:error, atom()}
  def verify(path) do
    Privacy.run(fn ->
      with {:ok, token} <- PrivateFiles.read(path),
           {:ok, identity} <- Credentials.authenticate(token) do
        {:ok, Map.take(identity, [:host_id, :credential_id]) |> Map.put(:verified, true)}
      else
        _ -> {:error, :galileo_credential_failed}
      end
    end)
  end

  @spec revoke(binary()) :: {:ok, map()} | {:error, atom()}
  def revoke(host) do
    Privacy.run(fn ->
      case Credentials.revoke(host) do
        {:ok, :ok} -> {:ok, %{host_id: host, revoked: true}}
        _ -> {:error, :galileo_credential_failed}
      end
    end)
    |> tap(fn
      {:ok, _} -> Marshall.Events.emit("galileo.credential_revoked", host_id: host)
      _ -> :ok
    end)
  end

  defp result({:ok, value} = ok, host, _outcome) when is_map(value) do
    Marshall.Events.emit("galileo.credential_rotated",
      host_id: Map.get(value, :host_id, host),
      credential_id: Map.get(value, :credential_id)
    )

    ok
  end

  defp result(_, _host, _outcome), do: {:error, :galileo_credential_failed}
end
