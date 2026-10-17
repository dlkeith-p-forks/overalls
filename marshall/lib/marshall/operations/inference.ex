defmodule Marshall.Operations.Inference do
  @moduledoc "Trusted Ziggy credential operations; only public metadata leaves the command."
  alias Marshall.Operations.{PrivateFiles, Privacy}
  alias Marshall.Inference.Credentials
  alias Marshall.Compute.Ledger
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;recovery] ziggy-operator-private-custody
  # Rotation MUST exclusively reserve a private output before changing authority
  # and sync the token before transaction commit. Output failures roll back
  # authority. Uncertain replies retain the file for explicit verification;
  # neither credentials nor provider keys may enter command output or arguments.
  @spec rotate(binary(), pos_integer(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def rotate(host, ttl, output) do
    Privacy.run(fn ->
      PrivateFiles.with_new(output, fn file ->
        Ledger.transaction(fn ->
          with {:ok, credential} <- Credentials.rotate(host, ttl),
               :ok <-
                 PrivateFiles.write_sync(file, output, credential.id <> "." <> credential.secret) do
            credential
          else
            _ -> Ledger.rollback(:inference_credential_failed)
          end
        end)
        |> case do
          {:ok, credential} ->
            Marshall.Events.emit("inference.credential_rotated",
              host_id: host,
              credential_id: credential.id
            )

            {:ok,
             %{host_id: host, credential_id: credential.id, expires_at: credential.expires_at}}

          _ ->
            {:error, :inference_credential_failed}
        end
      end)
    end)
  end

  @spec verify(Path.t()) :: {:ok, map()} | {:error, atom()}
  def verify(path) do
    Privacy.run(fn ->
      with {:ok, token} <- PrivateFiles.read(path),
           {:ok, identity} <- Credentials.authenticate(token) do
        {:ok, Map.take(identity, [:host_id, :credential_id]) |> Map.put(:verified, true)}
      else
        _ -> {:error, :inference_credential_failed}
      end
    end)
  end

  @spec revoke(binary()) :: {:ok, map()} | {:error, atom()}
  def revoke(host) do
    Privacy.run(fn ->
      case Credentials.revoke(host) do
        {:ok, :ok} -> {:ok, %{host_id: host, revoked: true}}
        _ -> {:error, :inference_credential_failed}
      end
    end)
  end
end
