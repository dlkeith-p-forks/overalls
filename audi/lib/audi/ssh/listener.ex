defmodule Audi.SSH.Listener do
  @moduledoc "OTP SSH listener exposing only a leased local guest-SSH stream."
  use GenServer
  alias Audi.SSH.{Channel, Proof}
  require Audi.Events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  # @cc [owner:ghuntley,label:security] audi-ssh-no-general-forwarding
  # Only verified key possession and the custom connect channel are enabled.
  # OS shells, subsystems and both TCP tunnel directions MUST stay disabled.
  # Shell/PTY requests may receive diagnostic-only setup guidance. Each
  # connection permits one channel; unauthenticated/idle sessions are bounded.
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server) do
    GenServer.call(server, :ready, 100)
  catch
    :exit, _ -> false
  end

  @impl true
  # @cc [owner:ghuntley,label:security;verification] audi-ssh-fixture-key-isolation
  # The production callback MUST retain certificate-first host-key negotiation.
  # An explicitly injected raw-key test callback MUST advertise only Ed25519 so
  # OTP can start the listener without a certificate the fixture does not own.
  def init(options) do
    key_callback = Keyword.get(options, :key_cb, Proof)

    certificate_ready = fn ->
      key_callback != Proof or
        match?(
          {:ok, _},
          Proof.host_certificate(:"ssh-ed25519-cert-v01@openssh.com",
            system_dir: options |> Keyword.fetch!(:host_key_dir) |> String.to_charlist()
          )
        )
    end

    true = certificate_ready.()

    :logger.update_process_metadata(%{audi_private: true})
    :ok = Audi.Privacy.install()
    host = Keyword.fetch!(options, :host_id)
    true = OverallsProtocol.uuid?(host)

    config = %{
      public_origin: Keyword.get(options, :public_origin),
      host_id: host,
      backend: Keyword.get(options, :backend, {Audi.SSH.Backend, nil})
    }

    public_key_algorithms =
      if key_callback == Proof,
        do: [:"ssh-ed25519-cert-v01@openssh.com" | :ssh.default_algorithms()[:public_key]],
        else: [:"ssh-ed25519"]

    result =
      :ssh.daemon(Keyword.get(options, :bind, {127, 0, 0, 1}), Keyword.fetch!(options, :port),
        system_dir: options |> Keyword.fetch!(:host_key_dir) |> String.to_charlist(),
        preferred_algorithms: [public_key: public_key_algorithms],
        auth_methods: ~c"publickey",
        no_auth_needed: false,
        pk_check_user: false,
        key_cb: key_callback,
        connectfun: &Proof.authenticated/3,
        ssh_cli: {Channel, [config]},
        shell: :disabled,
        exec: :disabled,
        subsystems: [],
        tcpip_tunnel_in: false,
        tcpip_tunnel_out: false,
        max_sessions: 128,
        max_channels: 1,
        parallel_login: true,
        negotiation_timeout: 10_000,
        max_initial_idle_time: 10_000,
        idle_time: 60_000,
        ssh_msg_debug_fun: fn _, _, _, _ -> :ok end,
        unexpectedfun: fn _, _ -> :skip end
      )

    case result do
      {:ok, daemon} ->
        owner = self()

        watcher =
          spawn(fn ->
            ref = Process.monitor(owner)

            receive do
              {:DOWN, ^ref, :process, ^owner, _} -> :ssh.stop_daemon(daemon)
              :stopped -> :ok
            end
          end)

        {:ok, info} = :ssh.daemon_info(daemon)
        Process.send_after(self(), :health, 1000)

        {:ok,
         %{
           daemon: daemon,
           watcher: watcher,
           port: Keyword.fetch!(info, :port),
           certificate_ready: certificate_ready
         }}

      _ ->
        {:stop, :listener_unavailable}
    end
  rescue
    _ -> {:stop, :invalid_configuration}
  end

  @impl true
  def handle_call(:port, _, state), do: {:reply, state.port, state}

  def handle_call(:ready, _, state),
    do:
      {:reply, match?({:ok, _}, :ssh.daemon_info(state.daemon)) and state.certificate_ready.(),
       state}

  @impl true
  def handle_info(:health, state) do
    case :ssh.daemon_info(state.daemon) do
      {:ok, _} ->
        Process.send_after(self(), :health, 1000)
        {:noreply, state}

      _ ->
        Audi.Events.emit("audi.ssh_listener_lost", [])
        {:stop, :listener_lost, state}
    end
  end

  @impl true
  def terminate(_, state) do
    :ssh.stop_daemon(state.daemon)
    send(state.watcher, :stopped)
    :ok
  end
end
