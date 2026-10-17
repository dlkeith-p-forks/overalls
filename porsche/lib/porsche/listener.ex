defmodule Porsche.Listener do
  @moduledoc "Bounded OTP SSH daemon exposing only Porsche management channels."
  use GenServer
  alias Porsche.{Client, Connection}
  alias Porsche.SSH.{Channel, Proof}
  require Porsche.Events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @spec port(pid()) :: non_neg_integer()
  def port(pid), do: GenServer.call(pid, :port)

  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server) do
    GenServer.call(server, :ready, 1000)
  catch
    :exit, _ -> false
  end

  # @cc [owner:ghuntley,label:security] porsche-daemon-management-only
  # The daemon MUST use public-key proof and custom management channels only.
  # OS shells, default Erlang evaluation, subsystems and TCP forwarding MUST be
  # disabled. Privacy filters MUST be installed before the listener accepts peers.

  # @cc [owner:ghuntley,label:recovery] porsche-daemon-owner-lifetime
  # Losing the listener owner MUST stop its daemon even when terminate/2 cannot
  # run. Health checks MUST use the documented daemon API rather than treating
  # the opaque daemon reference as a process identifier.

  # @cc [owner:ghuntley,label:security] porsche-host-certificate-before-daemon
  # With the default Proof callback, startup MUST validate a currently valid,
  # correctly signed single-principal host certificate matching the private
  # leaf key before calling ssh.daemon. Invalid material MUST stop with
  # invalid_configuration. Peer trust in its embedded CA remains client-owned.
  @impl true
  def init(options) do
    certificate_ready = fn ->
      Keyword.get(options, :key_cb, Proof) != Proof or
        match?(
          {:ok, _},
          Proof.host_certificate(:"ssh-ed25519-cert-v01@openssh.com",
            system_dir: options |> Keyword.fetch!(:host_key_dir) |> String.to_charlist()
          )
        )
    end

    true = certificate_ready.()

    :logger.update_process_metadata(%{porsche_private: true})
    :ok = Porsche.Privacy.install()
    client = Keyword.fetch!(options, :client)
    origin = Keyword.fetch!(options, :public_origin)
    {:ok, _} = Client.new(origin, client.token)
    request = Keyword.get(options, :request, &Client.request/4)
    config = %{client: client, public_origin: String.trim_trailing(origin, "/"), request: request}

    connected = fn user, peer, method ->
      :ok = Proof.authenticated(user, peer, method)

      {:ok, _} =
        Connection.open(self(), client,
          request: fn client, route, message -> request.(client, route, message, []) end
        )

      :ok
    end

    case :ssh.daemon(Keyword.get(options, :bind, {0, 0, 0, 0}), Keyword.fetch!(options, :port),
           system_dir: options |> Keyword.fetch!(:host_key_dir) |> String.to_charlist(),
           preferred_algorithms: [
             public_key:
               [:"ssh-ed25519-cert-v01@openssh.com"] ++ :ssh.default_algorithms()[:public_key]
           ],
           auth_methods: ~c"publickey",
           no_auth_needed: false,
           pk_check_user: false,
           key_cb: Keyword.get(options, :key_cb, Proof),
           connectfun: connected,
           ssh_cli: {Channel, [config]},
           shell: :disabled,
           exec: :disabled,
           subsystems: [],
           tcpip_tunnel_in: false,
           tcpip_tunnel_out: false,
           max_sessions: 4096,
           max_channels: 8,
           parallel_login: true,
           negotiation_timeout: 15_000,
           max_initial_idle_time: 30_000,
           idle_time: 60_000,
           ssh_msg_debug_fun: fn _, _, _, _ -> :ok end,
           unexpectedfun: fn _, _ -> :skip end
         ) do
      {:ok, daemon} ->
        owner = self()

        guardian =
          spawn(fn ->
            reference = Process.monitor(owner)

            receive do
              {:DOWN, ^reference, :process, ^owner, _} -> :ssh.stop_daemon(daemon)
              :listener_stopped -> :ok
            end
          end)

        Process.send_after(self(), :check_listener, 1000)
        {:ok, info} = :ssh.daemon_info(daemon)

        {:ok,
         %{
           daemon: daemon,
           guardian: guardian,
           port: Keyword.fetch!(info, :port),
           certificate_ready: certificate_ready
         }}

      {:error, _} ->
        Porsche.Events.emit("porsche.listener_lost", reason: :ssh_listener_unavailable)
        {:stop, :ssh_listener_unavailable}
    end
  rescue
    _ -> {:stop, :invalid_configuration}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:ready, _from, state),
    do:
      {:reply, match?({:ok, _}, :ssh.daemon_info(state.daemon)) and state.certificate_ready.(),
       state}

  @impl true
  def handle_info(:check_listener, state) do
    case :ssh.daemon_info(state.daemon) do
      {:ok, _} ->
        Process.send_after(self(), :check_listener, 1000)
        {:noreply, state}

      _ ->
        Porsche.Events.emit("porsche.listener_lost", reason: :ssh_listener_lost)
        {:stop, :ssh_listener_lost, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state) do
    :ssh.stop_daemon(state.daemon)
    send(state.guardian, :listener_stopped)
    :ok
  end
end
