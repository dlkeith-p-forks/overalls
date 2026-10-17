defmodule Lilly.Transfer.SSH do
  @moduledoc "Pinned per-relocation SSH producer for the native stream pipeline."
  require Lilly.Events
  alias Lilly.Transfer.{ExportRequest, Key, Stream}
  alias Lilly.Host.PrivateFiles

  @type request :: %{
          host_id: String.t(),
          relocation_id: String.t(),
          placement_id: String.t(),
          source_host_id: String.t()
        }

  @pull_reasons [
    :stream_busy,
    :stream_failed,
    :stream_producer_failed,
    :stream_consumer_failed,
    :stream_children_failed,
    :stream_pipe_failed,
    :stream_timeout,
    :stream_diagnostics_limit,
    :stream_revoked,
    :stream_unconfirmed,
    :stream_helper_unavailable
  ]

  # @cc [owner:ghuntley,label:security;recovery] ssh-pull-requires-current-transfer-authority
  # pull/5 and pull/6 require authenticated endpoint distribution, durable receive intent,
  # current source permit/reservations and no pool lock. It MUST use only the
  # existing per-relocation private key and pinned source host key, never ambient
  # SSH configuration, agents, forwarding or multiplexed sessions. Remote requests
  # contain only a fixed verb, relocation UUID and an optional
  # bounded shell-inert resume token; no paths or
  # caller shell text. Native stream completion is not a verified import or proof
  # that remote producers are reaped; source revocation remains independently required.
  @spec pull(Path.t(), request(), map(), Stream.consumer(), pos_integer()) ::
          :ok | {:error, atom()}
  @spec pull(Path.t(), request(), map(), Stream.consumer(), pos_integer(), String.t() | nil) ::
          :ok | {:error, atom()}
  @spec pull(
          Path.t(),
          request(),
          map(),
          Stream.consumer(),
          pos_integer(),
          String.t() | nil,
          non_neg_integer()
        ) :: :ok | {:error, atom()}
  @spec pull(
          Path.t(),
          request(),
          map(),
          Stream.consumer(),
          pos_integer(),
          String.t() | nil,
          non_neg_integer(),
          pid() | nil
        ) :: :ok | {:error, atom()}
  def pull(root, request, endpoint, consumer, timeout, token \\ nil, rate \\ 0, progress \\ nil) do
    with true <- safe_path?(root) and valid_request?(request),
         true <- is_integer(timeout) and timeout in 1000..86_400_000,
         {:ok, files} <-
           Key.connection(
             root,
             request.host_id,
             request.relocation_id,
             request.placement_id,
             request.source_host_id,
             endpoint
           ),
         {:ok, producer} <- transfer_command(endpoint, request, files, token) do
      pull_result(
        request,
        Stream.run(files.stream_dir, producer, consumer, timeout, rate, progress)
      )
    else
      {:error, :invalid_transfer_connection} -> pull_failed(request, :invalid_transfer_connection)
      _ -> pull_failed(request, :invalid_ssh_transfer)
    end
  end

  defp transfer_command(endpoint, request, files, nil), do: command(endpoint, request, files)

  defp transfer_command(endpoint, request, files, token),
    do: resume_command(endpoint, request, files, token)

  # @cc [owner:ghuntley,label:security;recovery] ssh-probe-is-bounded-connectivity-only
  # probe/5 requires current authenticated probe authority and reserved endpoints.
  # It MUST use the existing relocation key/pin and shared stream owner lock,
  # require the exact challenge response and successful SSH exit within 30 seconds.
  # No received bytes may be retained. Success is connectivity evidence only,
  # never permission to stop, export, import or activate a workload.
  @spec probe(Path.t(), request(), map(), String.t(), pos_integer()) :: :ok | {:error, atom()}
  def probe(root, request, endpoint, challenge, timeout) do
    with true <- safe_path?(root) and valid_request?(request),
         true <- OverallsProtocol.uuid?(challenge),
         true <- is_integer(timeout) and timeout in 1000..30_000,
         {:ok, files} <-
           Key.connection(
             root,
             request.host_id,
             request.relocation_id,
             request.placement_id,
             request.source_host_id,
             endpoint
           ),
         {:ok, producer} <- probe_command(endpoint, request, files, challenge),
         name = "probe-" <> challenge,
         directory = Path.dirname(files.identity_file),
         :ok <- PrivateFiles.write(directory, name, "lilly-probe-v3 " <> challenge <> "\n") do
      probe_result(
        request,
        Stream.run(
          files.stream_dir,
          producer,
          {:compare, Path.join(directory, name)},
          timeout
        )
      )
    else
      {:error, :invalid_transfer_connection} ->
        probe_failed(request, :invalid_transfer_connection)

      _ ->
        probe_failed(request, :invalid_ssh_transfer)
    end
  end

  # @cc [owner:ghuntley,label:security;observability] ssh-outcome-events-closed
  # Pull and probe outcome events MUST carry only the relocation identifier and
  # a closed reason atom; SSH argv, endpoints, host keys, resume tokens,
  # terminal bytes and challenge text MUST NOT be logged. Pin and host-key
  # rejections MUST use their closed connection-rejection atom.
  defp pull_result(_request, :ok), do: :ok

  defp pull_result(request, {:error, reason}) when reason in @pull_reasons,
    do: pull_failed(request, reason)

  defp pull_result(request, _), do: pull_failed(request, :invalid_ssh_transfer)

  defp pull_failed(request, reason) do
    Lilly.Events.emit("lilly.ssh_pull_failed",
      relocation_id: request.relocation_id,
      reason: reason
    )

    {:error, reason}
  end

  defp probe_result(request, :ok) do
    Lilly.Events.emit("lilly.ssh_probe_completed", relocation_id: request.relocation_id)
    :ok
  end

  defp probe_result(request, {:error, reason}) when reason in @pull_reasons,
    do: probe_failed(request, reason)

  defp probe_result(request, _), do: probe_failed(request, :invalid_ssh_transfer)

  defp probe_failed(request, reason) do
    Lilly.Events.emit("lilly.ssh_probe_failed",
      relocation_id: request.relocation_id,
      reason: reason
    )

    {:error, reason}
  end

  # @cc [owner:ghuntley,label:security] probe-command-retains-all-ssh-restrictions
  # probe_command/4 MUST use the same connection fields as command/3,
  # replacing only its closed remote verb with the canonical probe.
  @spec probe_command(map(), request(), map(), String.t()) ::
          {:ok, Stream.producer()} | {:error, atom()}
  def probe_command(endpoint, request, files, challenge) do
    with true <- OverallsProtocol.uuid?(challenge),
         {:ok, {:ssh, ssh}} <- command(endpoint, request, files) do
      {:ok, {:ssh, %{ssh | verb: {:probe, challenge}}}}
    else
      _ -> {:error, :invalid_ssh_transfer}
    end
  end

  # @cc [owner:ghuntley,label:security] resumed-ssh-retains-pinned-transport
  # resume_command/4 MUST preserve every ordinary SSH field and accept only
  # a bounded shell-inert token. The remote source MUST independently validate its
  # lineage against the live permit before sending; syntax alone grants no authority.
  @spec resume_command(map(), request(), map(), String.t()) ::
          {:ok, Stream.producer()} | {:error, atom()}
  def resume_command(endpoint, request, files, token) do
    with true <- ExportRequest.token?(token),
         {:ok, {:ssh, ssh}} <- command(endpoint, request, files),
         do: {:ok, {:ssh, %{ssh | verb: {:resume, token}}}},
         else: (_ -> {:error, :invalid_ssh_transfer})
  end

  # @cc [owner:ghuntley,label:security] ssh-command-has-no-ambient-authority
  # command/3 accepts trusted local file paths prepared by Key.connection/6 and
  # returns only typed connection fields: hostd derives the ssh command line
  # with its fixed options (the private known-hosts pin, one Ed25519 identity,
  # IPv4 only, no agent, forwarding, proxy or multiplexing) and runs it as
  # the service uid (hostd-transfer-stream-typed). Paths MUST exclude SSH
  # token/environment expansion syntax; peer strings MUST NOT select users,
  # commands, config files or executables.
  @spec command(map(), request(), map()) :: {:ok, Stream.producer()} | {:error, atom()}
  def command(endpoint, request, %{identity_file: identity, known_hosts: known}) do
    with {:ok, endpoint} <- OverallsProtocol.TransferSSH.endpoint(endpoint),
         true <- valid_request?(request) and safe_path?(identity) and safe_path?(known) do
      {:ok,
       {:ssh,
        %{
          address: endpoint["address"],
          port: endpoint["port"],
          source_host: request.source_host_id,
          relocation: request.relocation_id,
          identity: identity,
          known_hosts: known,
          verb: :export
        }}}
    else
      _ -> {:error, :invalid_ssh_transfer}
    end
  end

  def command(_, _, _), do: {:error, :invalid_ssh_transfer}

  defp valid_request?(
         %{
           host_id: host,
           relocation_id: relocation,
           placement_id: placement,
           source_host_id: source
         } = request
       )
       when map_size(request) == 4 do
    Enum.all?([host, relocation, placement, source], &OverallsProtocol.uuid?/1) and
      host != source
  end

  defp valid_request?(_), do: false

  defp safe_path?(value) when is_binary(value) and byte_size(value) in 1..4096 do
    Regex.match?(~r/\A\/[a-zA-Z0-9_.\/-]+\z/, value) and Path.expand(value) == value
  end

  defp safe_path?(_), do: false
end
