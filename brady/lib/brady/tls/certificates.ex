defmodule Brady.TLS.Certificates do
  @moduledoc "Runtime-provided signing credential adapter; never provisions a CA or modifies guest trust."
  use GenServer
  require Brady.Events
  alias X509.{Certificate, PrivateKey, PublicKey}
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec fetch(GenServer.server(), String.t()) ::
          {:ok, keyword()} | {:error, :certificate_unavailable}
  def fetch(server, host), do: GenServer.call(server, {:fetch, host}, 5_000)

  @impl true
  def init(opts) do
    with {:ok, cert_pem} <- read_private(Keyword.fetch!(opts, :certfile)),
         {:ok, key_pem} <- read_private(Keyword.fetch!(opts, :keyfile)),
         {:ok, issuer} <- Certificate.from_pem(cert_pem),
         {:ok, key} <- PrivateKey.from_pem(key_pem),
         true <- Certificate.public_key(issuer) == PublicKey.derive(key),
         {:Extension, _, _, {:BasicConstraints, true, _}} <-
           Certificate.extension(issuer, :basic_constraints),
         {:Extension, _, _, usage} <- Certificate.extension(issuer, :key_usage),
         true <- :keyCertSign in usage do
      {:ok, %{issuer: issuer, key: key, leaf_key: PrivateKey.new_ec(:secp256r1), cache: %{}}}
    else
      _ -> {:stop, :invalid_signing_credentials}
    end
  rescue
    _ -> {:stop, :invalid_signing_credentials}
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  # @cc [owner:ghuntley,label:security] brady-runtime-signing-custody
  # Signing MUST use a matching runtime-provided CA certificate/key from private
  # regular single-link files. Leaf names MUST pass hostname validation; cached
  # leaf material MUST be bounded and expired within five minutes. No key,
  # certificate, subject name or peer-derived error may enter diagnostics.
  @impl true
  def handle_call({:fetch, host}, _, state) do
    with {:ok, ^host} <- Brady.Destination.hostname(host) do
      now = System.monotonic_time(:second)
      cache = Map.filter(state.cache, fn {_, {expires, _}} -> expires > now end)

      case cache[host] do
        {_, options} ->
          {:reply, {:ok, options}, %{state | cache: cache}}

        nil ->
          options = issue(state, host)
          Brady.Events.emit("brady.certificate_signed", [])
          cache = if map_size(cache) >= 2048, do: %{}, else: cache
          {:reply, {:ok, options}, %{state | cache: Map.put(cache, host, {now + 300, options})}}
      end
    else
      _ -> {:reply, {:error, :certificate_unavailable}, state}
    end
  rescue
    _ -> {:reply, {:error, :certificate_unavailable}, state}
  end

  defp issue(state, host) do
    san =
      case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
        {:ok, {a, b, c, d}} -> [iPAddress: <<a, b, c, d>>]
        _ -> [host]
      end

    cert =
      Certificate.new(PublicKey.derive(state.leaf_key), "/CN=#{host}", state.issuer, state.key,
        template: :server,
        validity: 1,
        extensions: [subject_alt_name: Certificate.Extension.subject_alt_name(san)]
      )

    [
      cert: [Certificate.to_der(cert), Certificate.to_der(state.issuer)],
      key: {:ECPrivateKey, PrivateKey.to_der(state.leaf_key)}
    ]
  end

  defp read_private(path) do
    with {:ok, %{type: :regular, links: 1, mode: mode, size: size}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0 and size in 1..65_536,
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end
end
