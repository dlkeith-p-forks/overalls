defmodule Lilly.Host.Hostd do
  @moduledoc """
  This BEAM's single session with lilly-hostd (ADR-0176 decision 4).

  hostd holds every lease's `flock` and runs every utility under a lease.
  One `SOCK_SEQPACKET` connection carries all requests; replies are matched
  by request id. The session connects lazily, so a BEAM without a daemon
  still starts. Losing an established session stops this process: every
  lease holder monitors it, and hostd itself kills the session's commands
  and releases its leases.

  Production Lilly names its daemon with `LILLY_HOSTD_SOCKET`. Without it
  (evaluation tools, machine-test probes, unit tests) the session starts a
  private daemon that inherits this BEAM's environment, including PATH, and
  exits when this process does. Both daemons `flock` the same inodes, so
  exclusion holds between them; the private one keeps process-group custody.
  """
  use GenServer

  @version 1
  # One SOCK_SEQPACKET record: a 9-byte header and at most a 32 KiB chunk or a
  # 64 KiB request. Each recv returns exactly one record.
  @record 70_000

  # @cc [owner:ghuntley,label:security;protocol] hostd-utility-table-closed
  # The index of every utility MUST match lilly/native/hostd/src/utilities.rs.
  # ZFS reads and ZFS mutations are distinct entries so hostd can refuse a
  # mutation without a lease.
  @utilities %{
    image_copy: 0,
    mkfifo: 1,
    ssh_keygen: 2,
    kvm_probe: 3,
    resume_token: 4,
    flow_label: 5,
    zfs_namespace_unmount: 6,
    zfs_list: 7,
    zfs_get: 7,
    zfs_snapshot: 8,
    zfs_create: 8,
    zfs_destroy: 8,
    zfs_mount: 8,
    zfs_set: 8,
    zfs_rename: 8,
    zfs_unmount: 8,
    zfs_receive_abort: 8,
    truncate: 9,
    zpool_status: 10,
    zpool_get: 10,
    zpool_iostat: 10,
    mv: 11,
    rm: 12,
    stat: 13,
    findmnt: 14,
    realpath: 15,
    sync: 16,
    ip: 17,
    nft: 18,
    sysctl: 19,
    cp: 20,
    mount: 21,
    umount: 22,
    chown: 23,
    systemctl: 25,
    image_identity: 26,
    chmod: 27
  }

  @type mode :: :exclusive | :shared
  @type acquire_error :: :host_already_owned | :host_lock_unavailable
  @type run_error ::
          :command_failed
          | :command_timeout
          | :command_output_limit
          | :utility_unavailable
          | :host_lock_unavailable
          | :host_lock_required

  @spec start_link(keyword()) :: GenServer.on_start()
  # @cc [owner:ghuntley,label:recovery] hostd-session-adopted-by-supervisor
  # start_link/1 MUST adopt a session that code running before the
  # supervision tree (configuration loading reads through hostd) already
  # started: it links that process to the caller and returns its pid rather
  # than failing the application start with :already_started.
  def start_link(_options \\ []) do
    case GenServer.start_link(__MODULE__, nil, name: __MODULE__) do
      {:error, {:already_started, pid}} ->
        Process.link(pid)
        {:ok, pid}

      other ->
        other
    end
  end

  @doc "The utility names hostd can run."
  @spec utilities() :: [atom()]
  def utilities, do: Map.keys(@utilities)

  @doc """
  The session process, starting an unsupervised one in a BEAM that runs no
  Lilly application (probes and evaluation tools).
  """
  @spec session() :: {:ok, pid()} | {:error, :host_lock_unavailable}
  def session do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, nil, name: __MODULE__) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          _ -> {:error, :host_lock_unavailable}
        end

      pid ->
        {:ok, pid}
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] hostd-acquire-bounded
  # acquire/3 MUST return {:ok, lease_id} only when hostd granted the lease
  # to the calling process, which then holds it until release/1 or its own
  # death. hostd waits at most wait_ms in its FIFO queue; contention is
  # :host_already_owned and every other failure :host_lock_unavailable. A
  # grant that arrives after the caller gave up or died MUST be released at
  # once, never left held.
  @spec acquire(Path.t(), mode(), 0..120_000) ::
          {:ok, pos_integer(), pid()} | {:error, acquire_error()}
  def acquire(directory, mode, wait_ms) when mode in [:exclusive, :shared] do
    with {:ok, session} <- session() do
      tag = make_ref()

      try do
        case GenServer.call(session, {:acquire, tag, directory, mode, wait_ms}, wait_ms + 10_000) do
          {:ok, lease} -> {:ok, lease, session}
          {:error, _} = error -> error
        end
      catch
        :exit, _ ->
          GenServer.cast(session, {:abandon, tag})
          {:error, :host_lock_unavailable}
      end
    end
  end

  @doc "Release a lease after hostd killed and reaped its commands."
  @spec release(pid(), pos_integer()) :: :ok | {:error, :host_lock_release_unconfirmed}
  def release(session, lease) do
    GenServer.call(session, {:release, lease}, 30_000)
  catch
    :exit, _ -> {:error, :host_lock_release_unconfirmed}
  end

  # @cc [owner:ghuntley,label:security] hostd-run-under-lease
  # run/6 MUST send only a utility from the closed table and the caller's
  # argument list (never an executable path) under the given lease (0 for a
  # lease-less read, which hostd refuses for mutating utilities), and map
  # hostd's closed status to the same results LockedCommand returned. A
  # session that is gone or refuses the lease is :host_lock_unavailable.
  @spec run(pid(), non_neg_integer(), atom(), [String.t()], pos_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, run_error()}
  def run(session, lease, utility, arguments, timeout_ms, limit)
      when is_map_key(@utilities, utility) do
    GenServer.call(
      session,
      {:run, lease, Map.fetch!(@utilities, utility), arguments, timeout_ms, limit},
      timeout_ms + 10_000
    )
  catch
    :exit, _ -> {:error, :host_lock_unavailable}
  end

  # @cc [owner:ghuntley,label:recovery] durable-run-attachable
  # run_durable/7 MUST start a job under the caller's lease whose 32-byte key
  # lets any later session attach to its result: the job keeps running, and
  # keeps the lease, if this BEAM's session ends. A key whose job is still
  # running is refused as :job_running; attach/3 returns a finished result,
  # :job_running when its wait ends first, or :job_unknown.
  @spec run_durable(
          pid(),
          pos_integer(),
          <<_::256>>,
          atom(),
          [String.t()],
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, binary()} | {:error, run_error() | :job_running | :job_unknown}
  def run_durable(session, lease, <<_::256>> = key, utility, arguments, timeout_ms, limit)
      when is_map_key(@utilities, utility) do
    GenServer.call(
      session,
      {:run_durable, key, lease, Map.fetch!(@utilities, utility), arguments, timeout_ms, limit},
      timeout_ms + 10_000
    )
  catch
    :exit, _ -> {:error, :host_lock_unavailable}
  end

  @spec attach(pid(), <<_::256>>, 0..120_000) ::
          {:ok, binary()} | {:error, run_error() | :job_running | :job_unknown}
  def attach(session, <<_::256>> = key, wait_ms) do
    GenServer.call(session, {:attach, key, wait_ms}, wait_ms + 10_000)
  catch
    :exit, _ -> {:error, :host_lock_unavailable}
  end

  @typedoc "The fields of one typed VM launch; hostd derives the command line."
  @type launch :: %{
          placement: OverallsProtocol.uuid(),
          epoch: pos_integer(),
          generation: pos_integer(),
          uid: pos_integer(),
          memory_bytes: pos_integer(),
          vcpus: 1..64,
          firmware: boolean(),
          logging: boolean(),
          state_dir: Path.t(),
          namespace: String.t(),
          pool: Path.t()
        }

  # @cc [owner:ghuntley,label:security] hostd-launch-vm-typed
  # launch_vm/3 MUST send only the launch's typed fields under the caller's
  # lease: never an executable, path list or command line, which hostd
  # derives itself (vm-launch-argv-derived-by-hostd). Results map like run/6.
  @spec launch_vm(pid(), pos_integer(), launch()) :: {:ok, binary()} | {:error, run_error()}
  def launch_vm(session, lease, %{namespace: namespace, state_dir: state_dir} = launch)
      when byte_size(namespace) in 1..32 and byte_size(state_dir) in 1..45 do
    GenServer.call(session, {:launch_vm, lease, launch}, 20_000)
  catch
    :exit, _ -> {:error, :host_lock_unavailable}
  end

  @typedoc "The source of one guest dataset stream; hostd derives its command."
  @type stream_producer ::
          {:local_send, %{dataset: String.t(), placement: OverallsProtocol.uuid()}}
          | {:local_resume,
             %{
               dataset: String.t(),
               placement: OverallsProtocol.uuid(),
               to_guid: String.t(),
               token: String.t()
             }}
          | {:ssh,
             %{
               address: String.t(),
               port: 1..65_535,
               source_host: OverallsProtocol.uuid(),
               relocation: OverallsProtocol.uuid(),
               identity: Path.t(),
               known_hosts: Path.t(),
               verb: :export | {:resume, String.t()} | {:probe, OverallsProtocol.uuid()}
             }}

  @typedoc "The sink of one guest dataset stream; hostd derives its command."
  @type stream_consumer ::
          {:receive,
           %{
             dataset: String.t(),
             pool: Path.t(),
             placement: OverallsProtocol.uuid(),
             host: OverallsProtocol.uuid(),
             pool_id: OverallsProtocol.uuid(),
             nonce: String.t()
           }}
          | {:compare, Path.t()}

  @type stream_result ::
          {:exited, 0..255}
          | {:error,
             :stream_timeout
             | :stream_revoked
             | :invalid_stream
             | :utility_unavailable
             | run_error()}

  # @cc [owner:ghuntley,label:security] hostd-transfer-stream-typed
  # transfer_stream/6 MUST send only the stream's typed fields under the
  # caller's stream lease: never an executable, option or command line, which
  # hostd derives itself. A finished helper is {:exited, code}; a timeout,
  # cancellation, refusal or lost session is an error, never an exit code.
  @spec transfer_stream(
          pid(),
          pos_integer(),
          stream_producer(),
          stream_consumer(),
          1000..86_400_000,
          0..1_073_741_824
        ) :: stream_result()
  def transfer_stream(session, lease, producer, consumer, timeout_ms, rate)
      when timeout_ms in 1000..86_400_000 and rate in 0..1_073_741_824 do
    {producer_kind, producer_fields} = producer_fields(producer)
    {consumer_kind, consumer_fields} = consumer_fields(consumer)
    fields = producer_fields ++ consumer_fields

    if Enum.all?(fields, &(is_binary(&1) and not String.contains?(&1, <<0>>))) do
      body = [
        <<lease::64, timeout_ms::32, rate::32, producer_kind, consumer_kind>>,
        Enum.map(fields, &[&1, 0])
      ]

      GenServer.call(session, {:transfer_stream, body}, timeout_ms + 30_000)
    else
      {:error, :host_lock_unavailable}
    end
  catch
    :exit, _ -> {:error, :host_lock_unavailable}
  end

  defp producer_fields({:local_send, %{dataset: dataset, placement: placement}}),
    do: {1, [dataset, placement]}

  defp producer_fields(
         {:local_resume, %{dataset: dataset, placement: placement, to_guid: guid, token: token}}
       ),
       do: {2, [dataset, placement, guid, token]}

  defp producer_fields({:ssh, %{verb: verb} = ssh}) do
    common = [
      ssh.address,
      Integer.to_string(ssh.port),
      ssh.source_host,
      ssh.relocation,
      ssh.identity,
      ssh.known_hosts
    ]

    case verb do
      :export -> {3, common}
      {:resume, token} -> {4, common ++ [token]}
      {:probe, challenge} -> {5, common ++ [challenge]}
    end
  end

  defp consumer_fields({:receive, receive}),
    do:
      {1,
       [
         receive.dataset,
         receive.pool,
         receive.placement,
         receive.host,
         receive.pool_id,
         receive.nonce
       ]}

  defp consumer_fields({:compare, path}), do: {2, [path]}

  # @cc [owner:ghuntley,label:security] hostd-lends-no-descriptors
  # connect_unix/3 and bridge_netns_tcp/2 MUST send the caller's own
  # unconnected socket with the request and return :ok only when hostd
  # answered Connected for it; a refusal, a closed socket or a lost session is
  # :connect_failed. hostd never sends a descriptor back: the BEAM cannot
  # release a descriptor it did not create (ADR-0184), so every socket Lilly
  # uses stays one it created and closes.
  @spec connect_unix(:socket.socket(), Path.t(), 1..30_000) :: :ok | {:error, :connect_failed}
  def connect_unix(socket, path, timeout) do
    with {:ok, session} <- session() do
      GenServer.call(session, {:connect, 12, [<<timeout::32>>, path], socket}, timeout + 5000)
    end
  catch
    :exit, _ -> {:error, :connect_failed}
  end

  @type netns_tcp :: %{
          namespace: String.t(),
          device: String.t(),
          mark: non_neg_integer(),
          destination: :inet.ip4_address(),
          port: 1..65_535,
          source: :inet.ip4_address() | nil,
          timeout: 1..30_000
        }

  @doc """
  Bridge the caller's own unconnected Unix stream socket to a guest TCP
  connection that hostd dials inside the Lilly network namespace.
  """
  @spec bridge_netns_tcp(:socket.socket(), netns_tcp()) :: :ok | {:error, :connect_failed}
  def bridge_netns_tcp(socket, request) do
    {a, b, c, d} = request.destination
    {e, f, g, h} = request.source || {0, 0, 0, 0}

    body = [
      <<request.mark::32, a, b, c, d, request.port::16, e, f, g, h, request.timeout::32,
        byte_size(request.namespace)>>,
      request.namespace,
      request.device
    ]

    with {:ok, session} <- session() do
      GenServer.call(session, {:connect, 13, body, socket}, request.timeout + 5000)
    end
  catch
    :exit, _ -> {:error, :connect_failed}
  end

  @typedoc "A detached ingress bridge's key (ADR-0187)."
  @type bridge_key :: <<_::128>>

  @typedoc """
  What hostd exchanges with the guest before a detached bridge starts
  (ADR-0192): the preface Lilly derived, written to the guest, and the exact
  frame Lilly requires back within `ready` milliseconds. Both are empty and
  `ready` is 0 for preface-free services.
  """
  @type bridge_stage :: %{preface: binary(), expect: binary(), ready: 0..30_000}

  # @cc [owner:ghuntley,label:security;recovery] hostd-detached-ingress-client
  # bridge_ingress/5 MUST send `client`, the Audi connection this BEAM
  # accepted (a socket it created and later closes itself), with the request,
  # reading its descriptor number from the live port just before sending, and
  # return :ok only when hostd answered Connected: the guest was dialled, the
  # stage's preface written and its expected frame matched exactly, the
  # greeting written and a detached bridge named by `key` is running. A stage
  # is sent only within hostd's bounds (preface 4096 bytes, frame 256, a ready
  # wait of 0 exactly when no frame is expected, else 1..30000 ms). Any
  # refusal or a lost session is :connect_failed. ingress_bridges/0 lists the
  # live keys and end_ingress_bridge/1 returns :ok only once hostd confirmed
  # the bridge's scope empty.
  @spec bridge_ingress(:gen_tcp.socket(), bridge_key(), binary(), bridge_stage(), netns_tcp()) ::
          :ok | {:error, :connect_failed}
  def bridge_ingress(
        client,
        <<_::128>> = key,
        greeting,
        %{preface: preface, expect: expect, ready: ready},
        request
      )
      when byte_size(greeting) <= 256 and is_binary(preface) and byte_size(preface) <= 4096 and
             is_binary(expect) and byte_size(expect) <= 256 and is_integer(ready) and
             ((expect == <<>> and ready == 0) or (expect != <<>> and ready in 1..30_000)) do
    {a, b, c, d} = request.destination
    {e, f, g, h} = request.source || {0, 0, 0, 0}

    body = [
      key,
      <<byte_size(greeting)::16>>,
      greeting,
      <<byte_size(preface)::16>>,
      preface,
      <<byte_size(expect)::16>>,
      expect,
      <<ready::32>>,
      <<request.mark::32, a, b, c, d, request.port::16, e, f, g, h, request.timeout::32,
        byte_size(request.namespace)>>,
      request.namespace,
      request.device
    ]

    with {:ok, session} <- session(),
         :ok <-
           GenServer.call(
             session,
             {:connect_port, 14, body, client},
             request.timeout + ready + 10_000
           ) do
      :ok
    else
      _ -> {:error, :connect_failed}
    end
  catch
    :exit, _ -> {:error, :connect_failed}
  end

  def bridge_ingress(_, _, _, _, _), do: {:error, :connect_failed}

  @spec ingress_bridges() :: {:ok, [bridge_key()]} | {:error, :hostd_unavailable}
  def ingress_bridges do
    with {:ok, session} <- session(),
         {:ok, keys} <- GenServer.call(session, {:ingress_bridges}, 10_000) do
      {:ok, for(<<key::binary-size(16) <- keys>>, do: key)}
    else
      _ -> {:error, :hostd_unavailable}
    end
  catch
    :exit, _ -> {:error, :hostd_unavailable}
  end

  @spec end_ingress_bridge(bridge_key()) :: :ok | {:error, :bridge_end_unconfirmed}
  def end_ingress_bridge(<<_::128>> = key) do
    with {:ok, session} <- session(),
         :ok <- GenServer.call(session, {:end_ingress_bridge, key}, 20_000) do
      :ok
    else
      _ -> {:error, :bridge_end_unconfirmed}
    end
  catch
    :exit, _ -> {:error, :bridge_end_unconfirmed}
  end

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       socket: nil,
       next: 2,
       pending: %{},
       chunks: %{},
       leases: %{},
       owners: %{},
       abandoned: MapSet.new(),
       private: nil
     }}
  end

  @impl true
  def handle_call(request, from, %{socket: nil} = state) do
    with {:ok, path, state} <- daemon(state),
         {:ok, socket} <- connect(path) do
      handle_call(request, from, %{state | socket: socket})
    else
      _ -> {:reply, unavailable(request), state}
    end
  end

  def handle_call({:acquire, tag, directory, mode, wait_ms}, {caller, _} = from, state) do
    request = <<if(mode == :shared, do: 1, else: 0), wait_ms::32>> <> directory
    send_request(state, 2, request, {:acquire, from, caller, tag})
  end

  def handle_call({:release, lease}, from, state) do
    if Map.has_key?(state.leases, lease),
      do: send_request(state, 3, <<lease::64>>, {:release, from, lease}),
      else: {:reply, :ok, state}
  end

  def handle_call({:run, lease, utility, arguments, timeout_ms, limit}, from, state) do
    body = Enum.map(arguments, &[&1, 0])

    send_request(
      state,
      4,
      [<<lease::64, timeout_ms::32, limit::32, utility>>, body],
      {:run, from}
    )
  end

  def handle_call({:launch_vm, lease, launch}, from, state) do
    flags = if(launch.firmware, do: 1, else: 0) + if(launch.logging, do: 2, else: 0)

    send_request(
      state,
      10,
      [
        <<lease::64>>,
        launch.placement,
        <<launch.epoch::64, launch.generation::64, launch.uid::32, launch.memory_bytes::64,
          launch.vcpus, flags, byte_size(launch.state_dir), byte_size(launch.namespace)>>,
        launch.state_dir,
        launch.namespace,
        launch.pool
      ],
      {:run, from}
    )
  end

  def handle_call({:run_durable, key, lease, utility, arguments, timeout_ms, limit}, from, state) do
    body = Enum.map(arguments, &[&1, 0])

    send_request(
      state,
      6,
      [key, <<lease::64, timeout_ms::32, limit::32, utility>>, body],
      {:run, from}
    )
  end

  def handle_call({:transfer_stream, body}, from, state),
    do: send_request(state, 11, body, {:stream, from})

  # The descriptor number is read from the caller's live socket here, just
  # before it is sent, so a socket closed meanwhile is refused rather than its
  # reused number sent.
  def handle_call({:connect, op, body, socket}, from, state) do
    case :socket.getopt(socket, {:otp, :fd}) do
      {:ok, fd} when is_integer(fd) and fd >= 0 ->
        send_request(state, op, body, {:connect, from}, fd)

      _ ->
        {:reply, {:error, :connect_failed}, state}
    end
  end

  # A port's descriptor, read the same way as a socket's: a port closed
  # meanwhile is refused rather than its reused number sent.
  def handle_call({:connect_port, op, body, port}, from, state) do
    case :inet.getfd(port) do
      {:ok, fd} when is_integer(fd) and fd >= 0 ->
        send_request(state, op, body, {:connect, from}, fd)

      _ ->
        {:reply, {:error, :connect_failed}, state}
    end
  end

  def handle_call({:ingress_bridges}, from, state),
    do: send_request(state, 15, <<>>, {:keys, from})

  def handle_call({:end_ingress_bridge, key}, from, state),
    do: send_request(state, 16, key, {:end_bridge, from})

  def handle_call({:attach, key, wait_ms}, from, state),
    do: send_request(state, 7, [key, <<wait_ms::32>>], {:run, from})

  @impl true
  def handle_cast({:abandon, tag}, state),
    do: {:noreply, %{state | abandoned: MapSet.put(state.abandoned, tag)}}

  @impl true
  def handle_info({:"$socket", socket, :select, _}, %{socket: socket} = state),
    do: receive_all(state)

  def handle_info({:"$socket", socket, :abort, _}, %{socket: socket} = state),
    do: {:stop, :hostd_session_lost, state}

  def handle_info({:hostd_data, data}, state) do
    case reply(data, state) do
      {:ok, state} -> receive_all(state)
      :invalid -> {:stop, :hostd_session_lost, state}
    end
  end

  # A holder died: release its leases, which kills their commands in hostd.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {{_ref, held}, owners} = Map.pop(state.owners, pid, {nil, MapSet.new()})
    state = %{state | owners: owners}

    state =
      Enum.reduce(held, state, fn lease, acc ->
        {:noreply, acc} = send_request(acc, 3, <<lease::64>>, {:release, nil, lease})
        acc
      end)

    {:noreply, state}
  end

  # A private daemon that exits takes this session's leases with it.
  def handle_info({port, {:exit_status, _}}, %{private: {_, port}} = state),
    do: {:stop, :hostd_session_lost, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}) when socket != nil, do: :socket.close(socket)
  def terminate(_reason, _state), do: :ok

  defp unavailable({:release, _}), do: :ok
  defp unavailable(_), do: {:error, :host_lock_unavailable}

  # @cc [owner:ghuntley,label:security;recovery] hostd-private-daemon-only-without-socket
  # daemon/1 MUST use LILLY_HOSTD_SOCKET whenever it is set and never spawn a
  # daemon then. Without it, it MUST start one private lilly-hostd from PATH
  # whose socket lives in a fresh 0700 directory and whose stdin is this
  # process's port, so the daemon (and its leases) end with this session.
  defp daemon(%{private: {path, _port}} = state), do: {:ok, path, state}

  defp daemon(state) do
    case System.get_env("LILLY_HOSTD_SOCKET") do
      path when is_binary(path) and path != "" -> {:ok, path, state}
      _ -> spawn_private(state)
    end
  end

  defp spawn_private(state) do
    # sun_path is limited to 108 bytes: keep the socket path short.
    directory =
      Path.join("/tmp", "lilly-hostd-" <> Base.url_encode64(:crypto.strong_rand_bytes(9)))

    path = Path.join(directory, "s")

    with executable when is_binary(executable) <- System.find_executable("lilly-hostd"),
         :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700) do
      # A root tool's daemon treats Lilly's service uid as the owner of
      # Lilly's state, as the system daemon does (ADR-0182).
      service =
        case Lilly.Host.Privilege.service_uid() do
          0 -> []
          uid -> ["--service-uid", Integer.to_string(uid)]
        end

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          args: ["--socket", path, "--root", "/", "--stdin-lifetime" | service]
        ])

      if listening?(path, port, System.monotonic_time(:millisecond) + 10_000),
        do: {:ok, path, %{state | private: {path, port}}},
        else: :error
    else
      _ -> :error
    end
  end

  defp listening?(path, port, deadline) do
    cond do
      match?({:ok, %{type: :other}}, File.lstat(path)) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        receive do
          {^port, {:exit_status, _}} -> false
        after
          20 -> listening?(path, port, deadline)
        end
    end
  end

  # @cc [owner:ghuntley,label:security] hostd-session-handshake
  # connect/1 MUST establish a session only after hostd answered Hello with
  # this protocol version within two seconds; any other answer closes the
  # socket and reports the daemon unavailable.
  defp connect(path) do
    case :socket.open(:local, :seqpacket, :default) do
      {:ok, socket} ->
        with :ok <- :socket.connect(socket, %{family: :local, path: path}, 2000),
             :ok <- :socket.send(socket, <<1, 1::64, @version::32>>, 2000),
             {:ok, <<1, 1::64, @version::32>>} <- :socket.recv(socket, @record, 2000) do
          arm(socket)
          {:ok, socket}
        else
          _ ->
            :socket.close(socket)
            :error
        end

      _ ->
        :error
    end
  end

  # No request is outstanding right after Hello, so the first non-blocking
  # receive only registers interest; a record or error arriving instead is
  # handled like any later one.
  defp arm(socket) do
    case :socket.recv(socket, @record, [], :nowait) do
      {:select, _} -> :ok
      {:ok, data} -> send(self(), {:hostd_data, data})
      {:error, _} -> send(self(), {:"$socket", socket, :abort, :closed})
    end

    :ok
  end

  defp send_request(state, op, body, waiter, descriptor \\ nil) do
    id = state.next

    case transmit(state.socket, [<<op, id::64>>, body], descriptor) do
      :ok ->
        state = %{state | next: id + 1, pending: Map.put(state.pending, id, waiter)}
        {:noreply, state}

      {:error, _} ->
        {:stop, :hostd_session_lost, state}
    end
  end

  defp transmit(socket, datagram, nil), do: :socket.send(socket, datagram, 5000)

  defp transmit(socket, datagram, fd) do
    :socket.sendmsg(
      socket,
      %{
        iov: [IO.iodata_to_binary(datagram)],
        ctrl: [%{level: :socket, type: :rights, data: <<fd::native-signed-32>>}]
      },
      [],
      5000
    )
  end

  # Plain receive with no control buffer: should a datagram ever carry a
  # descriptor, the kernel discards (closes) it instead of leaking it here.
  defp receive_all(state) do
    case :socket.recv(state.socket, @record, [], :nowait) do
      {:ok, data} ->
        case reply(data, state) do
          {:ok, state} -> receive_all(state)
          :invalid -> {:stop, :hostd_session_lost, state}
        end

      {:select, _} ->
        {:noreply, state}

      {:error, _} ->
        {:stop, :hostd_session_lost, state}
    end
  end

  defp reply(<<kind, id::64, body::binary>>, state) when is_map_key(state.pending, id) do
    {waiter, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    case {kind, waiter, body} do
      {5, {:run, _} = run, chunk} ->
        {:ok,
         %{
           state
           | pending: Map.put(state.pending, id, run),
             chunks: Map.update(state.chunks, id, [chunk], &[chunk | &1])
         }}

      {6, {:run, from}, <<status, rest::binary>>} ->
        {chunks, all} = Map.pop(state.chunks, id, [])
        output = IO.iodata_to_binary(Enum.reverse([rest | chunks]))
        GenServer.reply(from, run_result(status, output))
        {:ok, %{state | chunks: all}}

      {3, {:run, from}, <<reason>>} ->
        GenServer.reply(from, {:error, refusal(reason)})
        {:ok, state}

      {6, {:stream, from}, body} ->
        GenServer.reply(from, stream_result(body))
        {:ok, state}

      {3, {:stream, from}, <<3>>} ->
        GenServer.reply(from, {:error, :invalid_stream})
        {:ok, state}

      {3, {:stream, from}, <<reason>>} ->
        GenServer.reply(from, {:error, refusal(reason)})
        {:ok, state}

      {8, {:connect, from}, <<>>} ->
        GenServer.reply(from, :ok)
        {:ok, state}

      {3, {:connect, from}, _} ->
        GenServer.reply(from, {:error, :connect_failed})
        {:ok, state}

      {6, {:keys, from}, <<0, keys::binary>>} when rem(byte_size(keys), 16) == 0 ->
        GenServer.reply(from, {:ok, keys})
        {:ok, state}

      {6, {:end_bridge, from}, <<0>>} ->
        GenServer.reply(from, :ok)
        {:ok, state}

      {3, {waiter, from}, _} when waiter in [:keys, :end_bridge] ->
        GenServer.reply(from, {:error, :hostd_refused})
        {:ok, state}

      {2, {:acquire, from, caller, tag}, <<lease::64>>} ->
        granted(state, from, caller, tag, lease)

      {3, {:acquire, from, _caller, tag}, <<reason>>} ->
        GenServer.reply(
          from,
          {:error, if(reason == 1, do: :host_already_owned, else: :host_lock_unavailable)}
        )

        {:ok, %{state | abandoned: MapSet.delete(state.abandoned, tag)}}

      {4, {:release, from, lease}, <<>>} ->
        if from, do: GenServer.reply(from, :ok)
        {:ok, forget(state, lease)}

      {3, {:release, from, lease}, _} ->
        if from, do: GenServer.reply(from, {:error, :host_lock_release_unconfirmed})
        {:ok, forget(state, lease)}

      _ ->
        :invalid
    end
  end

  defp reply(_data, _state), do: :invalid

  defp granted(state, from, caller, tag, lease) do
    if MapSet.member?(state.abandoned, tag) or not Process.alive?(caller) do
      {:noreply, state} =
        send_request(
          %{state | abandoned: MapSet.delete(state.abandoned, tag)},
          3,
          <<lease::64>>,
          {:release, nil, lease}
        )

      {:ok, state}
    else
      owners =
        Map.update(state.owners, caller, {Process.monitor(caller), MapSet.new([lease])}, fn
          {ref, leases} -> {ref, MapSet.put(leases, lease)}
        end)

      GenServer.reply(from, {:ok, lease})
      {:ok, %{state | owners: owners, leases: Map.put(state.leases, lease, caller)}}
    end
  end

  defp forget(state, lease) do
    {owner, leases} = Map.pop(state.leases, lease)

    owners =
      case Map.get(state.owners, owner) do
        {ref, held} ->
          held = MapSet.delete(held, lease)

          if MapSet.size(held) == 0 do
            Process.demonitor(ref, [:flush])
            Map.delete(state.owners, owner)
          else
            Map.put(state.owners, owner, {ref, held})
          end

        nil ->
          state.owners
      end

    %{state | leases: leases, owners: owners}
  end

  defp refusal(6), do: :host_lock_required
  defp refusal(8), do: :job_unknown
  defp refusal(9), do: :job_running
  defp refusal(_), do: :host_lock_unavailable

  defp stream_result(<<status, code>>) when status in [0, 1], do: {:exited, code}
  defp stream_result(<<2>>), do: {:error, :stream_timeout}
  defp stream_result(<<5>>), do: {:error, :stream_revoked}
  defp stream_result(<<4>>), do: {:error, :utility_unavailable}
  defp stream_result(_), do: {:error, :host_lock_unavailable}

  defp run_result(0, output), do: {:ok, output}
  defp run_result(1, _), do: {:error, :command_failed}
  defp run_result(2, _), do: {:error, :command_timeout}
  defp run_result(3, _), do: {:error, :command_output_limit}
  defp run_result(4, _), do: {:error, :utility_unavailable}
  defp run_result(_, _), do: {:error, :host_lock_unavailable}
end
