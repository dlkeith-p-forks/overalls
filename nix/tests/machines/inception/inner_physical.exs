# @cc [owner:ghuntley,label:verification] inception-inner-physical-proof
# The native fixture MUST verify the actual confined inner VMM and guest boot,
# preserve a flushed guest marker over stop/start, and verify physical deletion.
# Console bytes MUST remain withheld from all fixture diagnostics.
defmodule InceptionInnerPhysicalFixture do
  @moduledoc false
  alias Lilly.Host.PrivateFiles
  alias Lilly.Terminal.Vsock
  alias Lilly.VM.{Boot, Config, Disk, Driver, Observation, Spec, Unit}

  @type terminal :: %{socket: Vsock.socket(), control: Vsock.socket(), session_id: pos_integer()}

  def run do
    {:ok, config} = Lilly.Control.Config.load("/var/lib/inception/lilly.json")
    {:ok, command} = "/root/inception-native-command.json" |> File.read!() |> JSON.decode!()
                    |> OverallsProtocol.Execution.command()
    {:ok, spec} = command |> Map.take([:image_id, :pool_id, :profile, :slot, :vcpu, :memory_bytes, :disk_bytes])
                  |> Map.put(:id, command.placement_id) |> Spec.new()
    pool = Enum.find(config.pools, &(&1.id == command.pool_id))
    case System.fetch_env!("INCEPTION_NATIVE_ACTION") do
      "delete" ->
        false = Observation.running?(config.execution, pool, spec)
        false = File.exists?(Disk.path(pool, spec))
      "stop" ->
        {:ok, :stopped} = Unit.status(spec)
        true = File.regular?(Disk.path(pool, spec))
      action when action in ["create", "start"] ->
        true = Observation.running?(config.execution, pool, spec)
        :ok = Driver.ready(config.execution, pool, spec,
          execution_epoch: command.execution_epoch, generation: command.generation, timeout: 120_000)
        check = if action == "create",
          do: "umask 077; printf %s #{spec.id} > /root/inception-native-marker && sync /root/inception-native-marker",
          else: "test \"$(cat /root/inception-native-marker)\" = #{spec.id}"
        :ok = console(config.execution, spec, check)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] inception-inner-terminal-current-boot
  # Physical guest assertions MUST authenticate terminald with the persisted
  # current boot identity. Each assertion owns and retires one isolated root PTY;
  # authentication material and terminal bytes MUST remain out of diagnostics.
  defp console(config, spec, check) do
    {:ok, terminal} = connect_terminal(config, spec, deadline(30_000))
    try do
      marker = "NESTED_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      :ok = Vsock.write(terminal.socket, "\nif (#{check}) >/dev/null 2>&1; then printf '\\n#{marker}:pass\\n'; fi\n")
      wait(terminal.socket, "\n#{marker}:pass\n", deadline(30_000), "")
    after
      close_terminal(terminal)
    end
  end

  defp wait(socket, marker, deadline, tail) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise("Inner guest assertion timed out")
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])
        if :binary.match(body, marker) != :nomatch do
          :ok
        else
          length = min(byte_size(body), byte_size(marker))
          wait(socket, marker, deadline, binary_part(body, byte_size(body) - length, length))
        end
      {:error, :timeout} -> wait(socket, marker, deadline, tail)
      _ -> raise "Inner guest console unavailable"
    end
  end

  @spec connect_terminal(Config.t(), Spec.t(), integer()) ::
          {:ok, terminal()} | {:error, :terminal_unavailable}
  defp connect_terminal(config, spec, until) do
    directory = Path.join(config.state_dir, spec.id)
    result = with {:ok, intent} <- Lilly.VM.Intent.read(directory),
      {:ok, boot} <- Boot.current(directory, spec.id, {intent.execution_epoch, intent.generation}),
      {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, "vm.json")),
      {:ok, %{"pool_path" => pool}} when is_binary(pool) <- JSON.decode(bytes),
      identity = Map.put(boot, :uds_path,
        Path.join([pool, ".lilly-jails", "firecracker", spec.id, "root", "v.sock"])),
      {:ok, control} <- Vsock.connect(identity, timeout: 2_000) do
        create_terminal(control, identity)
      else
        _ -> {:error, :terminal_unavailable}
      end
    case result do
      {:error, :terminal_unavailable} = error ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(100)
          connect_terminal(config, spec, until)
        else
          error
        end
      other -> other
    end
  end

  @spec create_terminal(Vsock.socket(), Vsock.identity()) ::
          {:ok, terminal()} | {:error, :terminal_unavailable}
  defp create_terminal(control, identity) do
    with {:ok, created} <- Vsock.create(control, "root", "xterm-256color", 80, 24),
      {:ok, attached} <- Vsock.attach(identity, created.guest_session_id,
        created.attach_token, :rw, 0) do
      {:ok, %{socket: attached.socket, control: control, session_id: created.guest_session_id}}
    else
      _ ->
        Vsock.close(control)
        {:error, :terminal_unavailable}
    end
  end

  @spec close_terminal(terminal()) :: :ok
  defp close_terminal(terminal) do
    _ = Vsock.kill(terminal.control, terminal.session_id)
    Vsock.close(terminal.socket)
    Vsock.close(terminal.control)
  end

  @spec deadline(non_neg_integer()) :: integer()
  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds
end

InceptionInnerPhysicalFixture.run()
