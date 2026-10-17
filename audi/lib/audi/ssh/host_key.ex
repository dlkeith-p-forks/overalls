defmodule Audi.SSH.HostKey do
  @moduledoc "Public identity derived from the gateway's actual Ed25519 private key."

  # @cc [owner:ghuntley,label:security] audi-host-key-from-private-key
  # Publication MUST derive the public key from the configured private host key,
  # never trust a replaceable .pub sidecar. Errors MUST not expose private bytes
  # or parser exceptions. Callers MUST validate file custody before reading.
  @spec public(binary()) :: {:ok, binary()} | {:error, :invalid_host_key}
  def public(directory) do
    with {:ok, private} <-
           :ssh_file.host_key(:"ssh-ed25519", system_dir: String.to_charlist(directory)),
         public = :ssh_file.extract_public_key(private),
         blob when is_binary(blob) <- :ssh_file.encode(public, :ssh2_pubkey),
         {:ok, %{algorithm: "ssh-ed25519", public_key: key}} <-
           OverallsProtocol.SSHKey.from_blob(blob) do
      {:ok, key}
    else
      _ -> {:error, :invalid_host_key}
    end
  rescue
    _ -> {:error, :invalid_host_key}
  catch
    _, _ -> {:error, :invalid_host_key}
  end
end
