try do
# @cc [owner:ghuntley,label:verification] host-probe-real-tls-fence
# The probe MUST use the packaged Lilly control client against the fleet TLS
# listener with the host's enrolled credential file and the observed session and
# machine identity. It MUST print only the closed result class, never tokens.
[mode, credential_path, control_url, ca_path, session_id, epoch, machine_id] = System.argv()
{:ok, _} = Application.ensure_all_started(:ssl)
{:ok, envelope} = File.read(credential_path)
%{"host_id" => host_id, "credential" => token} = JSON.decode!(envelope)
true = Regex.match?(~r/^sha256:[0-9a-f]{64}$/, machine_id)

{:ok, client} =
  Lilly.Control.Client.new(control_url, host_id, token,
    protocol_version: 4,
    machine_id: machine_id,
    cacertfile: ca_path,
    control: :fleet_host_probe_control
  )

# The packaged client talks through the control socket its Link owns
# (ADR-0142). Wait for a welcome, or for a refusal the socket keeps
# reporting; either way the request below answers its closed class.
{:ok, _link} = Lilly.Control.Link.start_link(client)

Enum.reduce_while(1..100, nil, fn _, _ ->
  case OverallsProtocol.Control.Client.status(client.control) do
    :ready -> {:halt, :ready}
    {:disconnected, reason} when reason in [:refused, :unsupported_version] -> {:halt, reason}
    _ -> Process.sleep(100) && {:cont, nil}
  end
end)

result =
  case mode do
    "open" ->
      case Lilly.Control.Client.open(client, session_id) do
        {:ok, _session} -> :ok
        {:error, reason} -> {:error, reason}
      end

    "exchange" ->
      session = %{session_id: session_id, epoch: String.to_integer(epoch), pools: []}

      case Lilly.Control.Client.exchange_execution(client, session, nil, [], []) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
  end

label =
  case result do
    :ok -> "ok"
    {:error, reason} -> "error_" <> Atom.to_string(reason)
  end

IO.puts("#{mode}:#{label}")
rescue
  error -> IO.puts("probe_raised:" <> Atom.to_string(error.__struct__)); System.halt(1)
end
