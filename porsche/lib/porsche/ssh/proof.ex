defmodule Porsche.SSH.Proof do
  @moduledoc "OTP key callback and connection-owned proof of key possession."
  @behaviour :ssh_server_key_api
  alias OverallsProtocol.SSHKey
  require Porsche.Events

  @candidate {__MODULE__, :candidate}

  @impl true
  @spec host_certificate(atom(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def host_certificate(algorithm, options) do
    with {:ok, blob} <- :ssh_file.host_certificate(algorithm, options),
         {:ok, private} <- :ssh_file.host_key(:"ssh-ed25519", options),
         public = private |> :ssh_file.extract_public_key() |> :ssh_file.encode(:ssh2_pubkey),
         {:ok, key} <- OverallsProtocol.SSHKey.from_blob(public),
         true <-
           OverallsProtocol.SSHHostCertificate.valid_blob?(
             blob,
             key.public_key,
             System.system_time(:second)
           ) do
      {:ok, blob}
    else
      _ -> {:error, :invalid_host_certificate}
    end
  end

  @impl true
  def host_key(:"ssh-ed25519-cert-v01@openssh.com" = algorithm, options),
    do: :ssh_file.host_key(algorithm, options)

  def host_key(_, _), do: {:error, :unsupported_host_key}

  # @cc [owner:ghuntley,label:security] porsche-key-probe-is-not-proof
  # is_auth_key/3 MUST NOT open a Marshall session or establish account authority.
  # OTP invokes it before signature verification, including unsigned probes.
  # Candidate identity MUST stay local to the OTP connection process and be
  # replaced on every key attempt, including invalid candidates. Rejection MUST
  # log only the closed reason; key material, fingerprints and peers MUST NOT.
  @impl true
  def is_auth_key(key, _username, _options) do
    :logger.update_process_metadata(%{porsche_private: true})
    Process.delete(@candidate)

    case candidate(key) do
      {:ok, canonical} ->
        Process.put(@candidate, canonical)
        Overalls.Diagnostics.Metrics.record([:porsche, :ssh, :candidate], %{count: 1}, %{})
        true

      {:error, reason} ->
        Porsche.Events.emit("porsche.auth_denied", reason: reason)
        false
    end
  rescue
    _ -> false
  end

  # @cc [owner:ghuntley,label:security] porsche-proof-after-signature
  # Only OTP's successful publickey connectfun MAY promote the connection-local
  # candidate. The registration MUST belong to that same connection process and
  # disappear when it dies. SSH usernames MUST NOT select account identity.
  # Success MUST be logged without username, peer or key identity.
  @spec authenticated(term(), term(), term()) :: :ok
  def authenticated(_username, _peer, ~c"publickey") do
    case Process.delete(@candidate) do
      %{public_key: _, fingerprint: _, algorithm: _} = key ->
        case Registry.register(Porsche.SSH.Proofs, self(), key) do
          {:ok, _} ->
            Overalls.Diagnostics.Metrics.record([:porsche, :ssh, :proved], %{count: 1}, %{})
            Porsche.Events.emit("porsche.authenticated", [])
            :ok

          _ ->
            raise "SSH proof registration failed"
        end

      _ ->
        raise "SSH signature has no candidate key"
    end
  end

  def authenticated(_, _, _), do: raise("SSH requires public-key authentication")

  @spec lookup(pid()) :: {:ok, SSHKey.t()} | :error
  def lookup(connection) when is_pid(connection) do
    case Registry.lookup(Porsche.SSH.Proofs, connection) do
      [{^connection, key}] -> {:ok, key}
      _ -> :error
    end
  end

  defp candidate(key) do
    case SSHKey.from_blob(:ssh_file.encode(key, :ssh2_pubkey)) do
      {:ok, canonical} -> {:ok, canonical}
      _ -> {:error, :invalid}
    end
  end
end
