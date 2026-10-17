defmodule FleetAudiGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification;security] audi-real-guest-http-service
  # This fixture MUST start fixed HTTP services inside the actual Firecracker
  # guest through its console. It MUST NOT fabricate execution observations or
  # forward host sockets as guest services. Console content stays out of logs.
  @spec run(binary()) :: :ok
  def run(placement) do
    true = OverallsProtocol.uuid?(placement)
    python = System.fetch_env!("FLEET_GUEST_PYTHON")

    true =
      python == "/usr/bin/python3" or
        (String.starts_with?(python, "/nix/store/") and
           String.ends_with?(python, "/bin/python3"))

    program = """
    import http.server, threading, time, base64, hashlib, struct
    LOCK = threading.Lock()
    def bump():
      with LOCK:
        try:
          with open('/run/audi-guest-requests') as source: current = int(source.read().strip() or '0')
        except OSError: current = 0
        with open('/run/audi-guest-requests', 'w') as target: target.write(str(current + 1))
    class Handler(http.server.BaseHTTPRequestHandler):
      protocol_version = "HTTP/1.1"
      def log_message(self, *args): pass
      def do_GET(self):
        bump()
        self.close_connection = True
        if self.headers.get('Upgrade', '').lower() == 'websocket':
          self.send_response(101)
          self.send_header('Connection', 'Upgrade')
          self.send_header('Upgrade', 'websocket')
          accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
          self.send_header('Sec-WebSocket-Accept', accept)
          self.end_headers()
          while True:
            head = self.rfile.read(2)
            if len(head) != 2 or head[0] == 0x88: return
            size = head[1] & 127
            if size == 126: size = struct.unpack('!H', self.rfile.read(2))[0]
            if size == 127: size = struct.unpack('!Q', self.rfile.read(8))[0]
            if size > 1048576 or not head[1] & 128: return
            mask = self.rfile.read(4); data = self.rfile.read(size)
            if len(mask) != 4 or len(data) != size: return
            data = bytes(value ^ mask[i % 4] for i, value in enumerate(data))
            length = bytes([size]) if size < 126 else bytes([126]) + struct.pack('!H', size)
            self.wfile.write(bytes([head[0]]) + length + data); self.wfile.flush()
        self.send_response(200)
        self.send_header('Connection', 'close')
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        if self.path == '/stream':
          try:
            while True:
              self.wfile.write(b'audi-guest\\n'); self.wfile.flush(); time.sleep(.1)
          except (BrokenPipeError, ConnectionResetError): pass
        else: self.wfile.write(b'audi-guest\\n')
    for port in (8080, 3000):
      threading.Thread(target=http.server.ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever, daemon=True).start()
    threading.Event().wait()
    """

    encoded = Base.encode64(program)
    IO.puts(:stderr, "Audi fixture stage: attach")
    {:ok, socket} = Terminal.connect(placement)

    try do
      IO.puts(:stderr, "Audi fixture stage: shell")
      :ok = Terminal.ready(socket, 120_000)
      # @cc [owner:ghuntley,label:verification;security] guest-trust-before-network
      # Both NixOS and Ubuntu acceptance images MUST have installed the host
      # bundle before the first guest network activation.
      IO.puts(:stderr, "Audi fixture stage: trust-unit")
      command(socket, "systemctl is-active --quiet overalls-guest-trust.service")
      IO.puts(:stderr, "Audi fixture stage: trust-bundle")
      command(socket, "test -s /etc/ssl/certs/ca-certificates.crt")
      IO.puts(:stderr, "Audi fixture stage: trust-user")

      unprivileged_read =
        if python == "/usr/bin/python3",
          do: "su -s /bin/sh overalls-ssh -c 'test -r /etc/ssl/certs/ca-certificates.crt'",
          else: "sudo -u overalls-ssh -- test -r /etc/ssl/certs/ca-certificates.crt"

      command(socket, unprivileged_read)
      IO.puts(:stderr, "Audi fixture stage: trust-order")

      command(
        socket,
        "test $(systemctl show overalls-guest-trust.service -p ActiveEnterTimestampMonotonic --value) -le $(systemctl show lilly-network.service -p ActiveEnterTimestampMonotonic --value)"
      )

      IO.puts(:stderr, "Audi fixture stage: upload")
      command(socket, "printf %s #{encoded} | base64 -d > /root/audi-http.py")
      command(socket, "systemctl stop audi-http.service >/dev/null 2>&1 || true")
      IO.puts(:stderr, "Audi fixture stage: runtime")

      command(
        socket,
        "timeout 3 #{python} /root/audi-http.py >/dev/null 2>&1; test $? -eq 124"
      )

      IO.puts(:stderr, "Audi fixture stage: service")
      command(socket, "systemd-run --quiet --unit=audi-http #{python} /root/audi-http.py")
      IO.puts(:stderr, "Audi fixture stage: unit")

      command(
        socket,
        "timeout 10 sh -c 'until systemctl is-active --quiet audi-http.service; do sleep .1; done'"
      )

      IO.puts(:stderr, "Audi fixture stage: health")

      health = """
      import socket
      with socket.create_connection(("127.0.0.1", 8080), timeout=2) as connection:
        connection.settimeout(2)
        connection.sendall(b"GET / HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n")
        assert connection.recv(64).startswith(b"HTTP/1.1 200")
      """

      IO.puts(:stderr, "Audi fixture stage: health-upload")
      command(socket, "printf %s #{Base.encode64(health)} | base64 -d > /root/audi-health.py")
      IO.puts(:stderr, "Audi fixture stage: health-probe")
      command(socket, "sleep .3")

      command(
        socket,
        "timeout 5 #{python} /root/audi-health.py >/dev/null 2>&1"
      )

      IO.puts(:stderr, "Audi fixture stage: complete")
    after
      Terminal.close(socket)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] audi-inner-ssh-host-key
  # The real guest's Ed25519 public key MUST remain inspectable for identity
  # assertions; the console MUST NOT install any guest login key or client trust.
  @spec ssh(binary(), Path.t()) :: :ok
  def ssh(placement, output) do
    true = OverallsProtocol.uuid?(placement)
    IO.puts(:stderr, "Audi fixture stage: ssh-attach")
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)

      IO.puts(:stderr, "Audi fixture stage: ssh-dns")
      command(socket, "getent ahostsv4 ssh.integration.internal >/dev/null")
      IO.puts(:stderr, "Audi fixture stage: ssh-roster-sync")

      try do
        command(socket, "systemctl start overalls-ssh-sync.service")
      rescue
        error ->
          try do
            unit_diagnostics(socket)
          rescue
            _ -> :ok
          end

          try do
            ssh_events(socket)
          rescue
            _ -> :ok
          end

          reraise error, __STACKTRACE__
      end

      IO.puts(:stderr, "Audi fixture stage: ssh-service")
      command(socket, "systemctl start sshd.service && systemctl is-active --quiet sshd.service")
      save_ssh_host_key(socket, output)
    after
      Terminal.close(socket)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] audi-fresh-guest-host-key-readonly
  # A fresh VM's public host key MAY be read from its console for identity checks;
  # this probe MUST NOT start roster synchronization or the SSH listener.
  @spec ssh_host_key(binary(), Path.t()) :: :ok
  def ssh_host_key(placement, output) do
    true = OverallsProtocol.uuid?(placement)
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)
      save_ssh_host_key(socket, output)
    after
      Terminal.close(socket)
    end
  end

  @spec save_ssh_host_key(Terminal.t(), Path.t()) :: :ok
  defp save_ssh_host_key(socket, output) do
    IO.puts(:stderr, "Audi fixture stage: ssh-host-key")
    tag = "HOST_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    :ok =
      Terminal.write(
        socket,
        "printf '\\n%s' #{tag}; cat /run/overalls-ssh-host/ssh_host_ed25519_key.pub\n"
      )

    host_key = host_key(socket, tag, System.monotonic_time(:millisecond) + 10_000, "")
    File.write(output, host_key <> "\n", [:exclusive])
  end

  @spec ssh_diagnostics(binary()) :: :ok
  def ssh_diagnostics(placement) do
    true = OverallsProtocol.uuid?(placement)
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)
      ssh_events(socket)
      ssh_state(socket)
    after
      Terminal.close(socket)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] audi-ssh-sync-state-bounded
  # Roster sync state for a failed SSH login: only fixed keys with short
  # lowercase/numeric values (unit results, counts, booleans). Never account
  # names, keys, roster content or console text.
  @spec ssh_state(Terminal.t()) :: :ok
  defp ssh_state(socket) do
    tag = "AUDI_STATE_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    probe =
      Enum.join(
        [
          "printf '\\n%s\\n' #{tag}",
          "echo SYNC_RESULT=$(systemctl show -P Result overalls-ssh-sync.service)",
          "echo SYNC_STATUS=$(systemctl show -P ExecMainStatus overalls-ssh-sync.service)",
          "echo SYNC_TIMER=$(systemctl is-active overalls-ssh-sync.timer)",
          "echo SSHD=$(systemctl is-active sshd.service ssh.service | head -1)",
          "echo READY=$(test -e /run/overalls-ssh-ready && echo yes || echo no)",
          "echo ACCOUNTS=$(grep -o '\"uid\"' /var/lib/overalls-ssh/accounts.json 2>/dev/null | wc -l)",
          "echo PASSWD_GUEST=$(awk -F: '$3 >= 200000 && $3 <= 999999' /etc/passwd | wc -l)",
          "echo RECONCILED=$(journalctl --no-pager -o cat -u overalls-ssh-sync.service | grep -c ssh.roster_reconciled)",
          "printf '\\n%s_END\\n' #{tag}"
        ],
        "; "
      )

    :ok = Terminal.write(socket, probe <> "\n")
    ssh_state(socket, tag, System.monotonic_time(:millisecond) + 10_000, "")
  end

  @spec ssh_state(Terminal.t(), binary(), integer(), binary()) :: :ok
  defp ssh_state(socket, tag, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = :binary.replace(tail <> bytes, "\r", "", [:global])

        if String.contains?(data, tag <> "_END") do
          [_, records] = String.split(data, tag <> "\n", parts: 2)
          [records, _] = String.split(records, tag <> "_END", parts: 2)

          ~r/^(SYNC_RESULT|SYNC_STATUS|SYNC_TIMER|SSHD|READY|ACCOUNTS|PASSWD_GUEST|RECONCILED)=([a-z0-9-]{0,24})$/m
          |> Regex.scan(records, capture: :all_but_first)
          |> Enum.each(fn [key, value] ->
            IO.puts(:stderr, "Audi SSH sync state: #{key}=#{value}")
          end)

          :ok
        else
          ssh_state(
            socket,
            tag,
            deadline,
            binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
          )
        end

      {:error, :timeout} ->
        ssh_state(socket, tag, deadline, tail)

      _ ->
        :ok
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-ssh-listener-restarts-after-roster
  # A successful later roster refresh MUST reopen an inactive sshd listener.
  # The console fixture changes only this guest's SSH units.
  @spec ssh_recover(binary(), binary()) :: :ok
  def ssh_recover(placement, unit) do
    true = OverallsProtocol.uuid?(placement)
    true = unit in ["ssh.service", "sshd.service"]
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)
      command(socket, "systemctl stop #{unit}")
      command(socket, "systemctl start overalls-ssh-sync.service")

      command(
        socket,
        "timeout 20 sh -c 'until systemctl is-active --quiet #{unit}; do sleep .2; done'"
      )
    after
      Terminal.close(socket)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-guest-readiness-bounded-diagnostics
  # Failed relocation may report only fixed unit activity and roster presence;
  # never emit guest console content, key material or service environment.
  @spec ssh_status(binary()) :: :ok
  def ssh_status(placement) do
    true = OverallsProtocol.uuid?(placement)
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)
      unit_diagnostics(socket)
    after
      Terminal.close(socket)
    end
  end

  @spec unit_diagnostics(Terminal.t()) :: :ok
  defp unit_diagnostics(socket) do
    checks = [
      {"multi_user", "systemctl is-active --quiet multi-user.target"},
      {"network", "systemctl is-active --quiet lilly-network.service"},
      {"private_dns", "systemctl is-active --quiet lilly-private-dns.service"},
      {"ssh_sync_failed", "systemctl is-failed --quiet overalls-ssh-sync.service"},
      {"ssh_sync_exit_code",
       "test \"$(systemctl show overalls-ssh-sync.service --property=Result --value)\" = exit-code"},
      {"ssh_sync_dependency",
       "test \"$(systemctl show overalls-ssh-sync.service --property=Result --value)\" = dependency"},
      {"ssh_sync_timeout",
       "test \"$(systemctl show overalls-ssh-sync.service --property=Result --value)\" = timeout"},
      {"ssh_sync_start_limit",
       "test \"$(systemctl show overalls-ssh-sync.service --property=Result --value)\" = start-limit-hit"},
      {"ssh_sync_success",
       "test \"$(systemctl show overalls-ssh-sync.service --property=Result --value)\" = success"},
      {"ssh_timer", "systemctl is-active --quiet overalls-ssh-sync.timer"},
      {"sshd", "systemctl is-active --quiet sshd.service"},
      {"ssh", "systemctl is-active --quiet ssh.service"},
      {"readiness", "systemctl is-active --quiet lilly-readiness.service"},
      {"ssh_ready", "test -e /run/overalls-ssh-ready"},
      {"roster", "test -s /var/lib/overalls-ssh/accounts.json"}
    ]

    status =
      Map.new(checks, fn {name, probe} ->
        active =
          try do
            command(socket, probe)
            true
          rescue
            _ -> false
          end

        {name, active}
      end)

    IO.puts(:stderr, JSON.encode!(%{event: "audi.guest_readiness_diagnostic", status: status}))
    :ok
  end

  @spec ssh_events(Terminal.t()) :: :ok
  defp ssh_events(socket) do
    tag = "AUDI_EVENTS_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    :ok =
      Terminal.write(
        socket,
        "printf '\\n%s\\n' #{tag}; journalctl --no-pager -o cat -n 1000 | grep -oE '\"event\":\"ssh\\.[a-z_]+\"|account is locked|Invalid user|Failed publickey|AuthorizedKeysCommand|Authentication refused|failed, status [0-9]+|Permission denied|No such file or directory|not found|Could not stat|Unsafe|path is not absolute|contains invalid quotes|yielded no arguments|execve|exited on signal [0-9]+' | grep -v '\"event\":\"ssh.roster_reconciled\"' | tail -32; printf '\\n%s_END\\n' #{tag}\n"
      )

    ssh_events(socket, tag, System.monotonic_time(:millisecond) + 10_000, "")
  end

  @spec ssh_events(Terminal.t(), binary(), integer(), binary()) :: :ok
  defp ssh_events(socket, tag, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = :binary.replace(tail <> bytes, "\r", "", [:global])

        if String.contains?(data, tag <> "_END") do
          [_, records] = String.split(data, tag <> "\n", parts: 2)
          [records, _] = String.split(records, tag <> "_END", parts: 2)

          records
          |> then(&Regex.scan(~r/"event":"(ssh\.[a-z_]+)"/, &1, capture: :all_but_first))
          |> Enum.each(fn [event] -> IO.puts(:stderr, "Audi SSH helper event: #{event}") end)

          for {pattern, event} <- [
                {"account is locked", "ssh.account_locked"},
                {"Invalid user", "ssh.invalid_user"},
                {"Failed publickey", "ssh.publickey_failed"},
                {"AuthorizedKeysCommand", "ssh.callback_failed"},
                {"failed, status 1", "ssh.callback_exit_1"},
                {"failed, status 127", "ssh.callback_exit_127"},
                {"Permission denied", "ssh.callback_permission_denied"},
                {"No such file or directory", "ssh.callback_path_missing"},
                {"not found", "ssh.callback_user_missing"},
                {"Could not stat", "ssh.callback_stat_failed"},
                {"Unsafe", "ssh.callback_unsafe_path"},
                {"path is not absolute", "ssh.callback_relative_path"},
                {"contains invalid quotes", "ssh.callback_invalid_config"},
                {"yielded no arguments", "ssh.callback_empty_config"},
                {"execve", "ssh.callback_exec_failed"},
                {"exited on signal", "ssh.callback_signaled"},
                {"Authentication refused", "ssh.authentication_refused"}
              ],
              String.contains?(records, pattern) do
            IO.puts(:stderr, "Audi SSH guest auth event: #{event}")
          end

          :ok
        else
          ssh_events(
            socket,
            tag,
            deadline,
            binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
          )
        end

      {:error, :timeout} ->
        ssh_events(socket, tag, deadline, tail)

      _ ->
        :ok
    end
  end

  @spec host_key(Terminal.t(), binary(), integer(), binary()) :: binary()
  defp host_key(socket, tag, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = :binary.replace(tail <> bytes, "\r", "", [:global])

        case Regex.run(~r/#{tag}(ssh-ed25519 [A-Za-z0-9+\/=]+)[^\n]*\n/, data,
               capture: :all_but_first
             ) do
          [line] ->
            {:ok, %{algorithm: "ssh-ed25519", public_key: canonical}} =
              OverallsProtocol.SSHKey.parse(line)

            canonical

          _ ->
            host_key(
              socket,
              tag,
              deadline,
              binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
            )
        end

      {:error, :timeout} ->
        host_key(socket, tag, deadline, tail)

      _ ->
        raise "guest host key unavailable"
    end
  end

  # @cc [owner:ghuntley,label:verification] audi-guest-mark-isolation
  # Guest-originated traffic, even with the guest's own SO_MARK, MUST NOT inherit
  # Lilly's privileged host socket exception. Targets MUST be validated fixture
  # IPv4 listeners, not commands or paths supplied to the guest shell.
  @spec isolation(binary(), Path.t()) :: :ok
  def isolation(placement, target_file) do
    true = OverallsProtocol.uuid?(placement)
    %{"targets" => targets} = target_file |> File.read!() |> JSON.decode!()
    true = is_list(targets) and length(targets) in 1..8

    for address <- targets do
      {:ok, {_, _, _, _} = ip} = :inet.parse_strict_address(String.to_charlist(address))
      true = List.to_string(:inet.ntoa(ip)) == address
    end

    script = """
    import socket
    for address in #{JSON.encode!(targets)}:
      for mark in (0, 0x41554457):
        connection = socket.socket()
        connection.settimeout(1)
        if mark: connection.setsockopt(socket.SOL_SOCKET, 36, mark)
        try:
          connection.connect((address, 8080))
        except OSError: pass
        else: raise AssertionError('guest network boundary bypassed')
        finally: connection.close()
    """

    encoded = Base.encode64(script)
    python = System.fetch_env!("FLEET_GUEST_PYTHON")
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)

      command(
        socket,
        "printf %s #{encoded} | base64 -d > /root/audi-isolation.py && #{python} /root/audi-isolation.py"
      )
    after
      Terminal.close(socket)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] audi-guest-origin-contact-counter
  # The refusal matrix MUST read the real guest's own served-request counter
  # through one held console attachment, polling only the driver's opaque marker
  # files. Counter values, never console content or credentials, cross to the
  # host; a terminal marker MUST end the loop with the console closed.
  @spec counters(binary(), Path.t()) :: :ok
  def counters(placement, directory) do
    true = OverallsProtocol.uuid?(placement)
    true = Path.basename(directory) == "audi-counters"
    deadline = System.monotonic_time(:millisecond) + 1_200_000
    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)
      counter_loop(socket, directory, 0, deadline)
    after
      Terminal.close(socket)
    end
  end

  @spec counter_loop(Terminal.t(), Path.t(), non_neg_integer(), integer()) :: :ok
  defp counter_loop(socket, directory, sequence, deadline) do
    cond do
      File.regular?(Path.join(directory, "done")) ->
        :ok

      File.regular?(Path.join(directory, "poll-#{sequence}")) ->
        count = guest_counter(socket)
        File.write!(Path.join(directory, "count-#{sequence}"), Integer.to_string(count) <> "\n")
        counter_loop(socket, directory, sequence + 1, deadline)

      System.monotonic_time(:millisecond) >= deadline ->
        raise "Audi counter watch deadline exceeded"

      true ->
        Process.sleep(100)
        counter_loop(socket, directory, sequence, deadline)
    end
  end

  @spec guest_counter(Terminal.t()) :: non_neg_integer()
  defp guest_counter(socket) do
    tag = "audi-count-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    :ok =
      Terminal.write(
        socket,
        "printf '\\n%s\\n' #{tag}_BEGIN; cat /run/audi-guest-requests 2>/dev/null || echo 0; printf '%s\\n' #{tag}_END\n"
      )

    counter_value(socket, tag, System.monotonic_time(:millisecond) + 10_000, "")
  end

  @spec counter_value(Terminal.t(), binary(), integer(), binary()) :: non_neg_integer()
  defp counter_value(socket, tag, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = :binary.replace(tail <> bytes, "\r", "", [:global])

        if String.contains?(data, tag <> "_END") do
          [_, block] = String.split(data, tag <> "_BEGIN\n", parts: 2)
          [value, _] = String.split(block, tag <> "_END", parts: 2)
          {count, ""} = Integer.parse(String.trim(value))
          true = count >= 0
          count
        else
          counter_value(
            socket,
            tag,
            deadline,
            binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
          )
        end

      {:error, :timeout} ->
        counter_value(socket, tag, deadline, tail)

      _ ->
        raise "guest console unavailable"
    end
  end

  @spec command(Terminal.t(), binary()) :: :ok
  defp command(socket, command) do
    tag = "audi-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    :ok = Terminal.write(socket, command <> "; r=$?; printf '\\n%s%s\\n' #{tag} \"$r\"\n")
    wait_status(socket, tag, System.monotonic_time(:millisecond) + 20_000, "")
  end

  @spec wait_status(Terminal.t(), binary(), integer(), binary()) :: :ok
  defp wait_status(socket, tag, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = :binary.replace(tail <> bytes, "\r", "", [:global])

        case Regex.run(~r/#{tag}([0-9]{1,3})\n/, data, capture: :all_but_first) do
          ["0"] ->
            :ok

          [status] ->
            IO.puts(:stderr, "Audi fixture command exit: #{status}")
            raise "guest command failed"

          _ ->
            wait_status(
              socket,
              tag,
              deadline,
              binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
            )
        end

      {:error, :timeout} ->
        wait_status(socket, tag, deadline, tail)

      _ ->
        raise "guest console unavailable"
    end
  end

  defp wait(socket, marker, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = tail <> bytes

        unless String.contains?(data, marker),
          do:
            wait(
              socket,
              marker,
              deadline,
              binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
            )

      {:error, :timeout} ->
        wait(socket, marker, deadline, tail)

      _ ->
        raise "guest console unavailable"
    end
  end
end

try do
  case System.argv() do
    [placement] -> FleetAudiGuest.run(placement)
    ["ssh", placement, output] -> FleetAudiGuest.ssh(placement, output)
    ["ssh-host-key", placement, output] -> FleetAudiGuest.ssh_host_key(placement, output)
    ["ssh-diagnostics", placement] -> FleetAudiGuest.ssh_diagnostics(placement)
    ["ssh-recover", placement, unit] -> FleetAudiGuest.ssh_recover(placement, unit)
    ["ssh-status", placement] -> FleetAudiGuest.ssh_status(placement)
    ["isolation", placement, targets] -> FleetAudiGuest.isolation(placement, targets)
    ["counters", placement, directory] -> FleetAudiGuest.counters(placement, directory)
  end

  IO.puts("Audi guest HTTP services ready")
rescue
  _ ->
    IO.puts(:stderr, "Audi guest preparation failed; console content withheld")
    System.halt(1)
end
