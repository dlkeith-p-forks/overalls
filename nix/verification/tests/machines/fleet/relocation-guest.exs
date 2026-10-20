defmodule FleetRelocationGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification] relocation-guest-real-persistent-writes
  # Only validated placement identities and fixed fixture commands may reach the
  # real guest console. Preparation MUST sync a marker and start a continuous
  # synced writer; before-stop MUST sync a distinct marker. Destination checks
  # MUST read both from the booted guest. Terminal bytes MUST remain private.

  # @cc [owner:ghuntley,label:verification] unrelated-writer-remains-live
  # verify-live MUST require the existing writer service and observe its synced
  # counter advance within a bounded wait; old disk contents alone cannot prove
  # continued write availability under another workload's storage pressure.

  # @cc [owner:ghuntley,label:verification] clone-guest-divergent-markers
  # The clone-write/clone-inherit/clone-write-post/clone-check actions MUST
  # validate every placement identity as a UUID and use only fixed
  # /root/clone-own-<uuid> and /root/clone-post-<uuid> paths. Divergence checks
  # require a distinct validated peer and MUST assert marker presence/absence
  # from the guest console, never from fixture-written host state.
  @spec run(String.t(), String.t()) :: :ok
  def run(action, placement), do: run(action, placement, nil)

  @spec run(String.t(), String.t(), String.t() | nil) :: :ok
  # @cc [owner:ghuntley,label:verification;security] clone-early-boot-observations
  # This disposable observer MUST collect only thirty validated boolean snapshots
  # without changing intent, boot, deadlines or outcomes. The fixed output MUST
  # remain private; snapshots cannot establish execution or readiness authority.
  def run("boot-observations", placement, nil) do
    true = OverallsProtocol.uuid?(placement)

    observations =
      for _ <- 1..30 do
        observation = Terminal.observe_boot(placement)
        Process.sleep(2_000)
        observation
      end

    path = "/run/clone-native-boot-observations.json"
    :ok = File.write(path, JSON.encode!(observations), [:exclusive])
    :ok = File.chmod(path, 0o600)
    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] interrupted-capture-native-boundary
  # This privileged fixture MUST use real local records and the caller's queued
  # Marshall pause revision. It MUST journal capturing then pause the confined
  # VMM, without creating or publishing snapshot bytes. Only a later explicit
  # terminal lifecycle command may discard this interrupted continuation.
  def run("interrupted-capture", placement, revision) when is_binary(revision) do
    alias Lilly.VM.{API, Boot, Checkpoint, Intent, Jail, Observation, Spec}
    true = OverallsProtocol.uuid?(placement)
    [epoch, generation] = revision |> String.split(":") |> Enum.map(&String.to_integer/1)
    true = epoch > 0 and generation > 0
    {:ok, config} = Lilly.Control.Config.load("/run/lilly-release/config.json")
    directory = Path.join(config.execution.state_dir, placement)
    {:ok, lock} = Lilly.Host.Lock.acquire(Path.join(directory, "lock"), 2_000)

    try do
      {:ok, bytes} = Lilly.Host.PrivateFiles.read_secret(Path.join(directory, "vm.json"))
      %{"pool_path" => pool_path, "spec" => wire} = JSON.decode!(bytes)
      pool = Enum.find(config.pools, &(&1.path == pool_path))
      true = not is_nil(pool)

      profile =
        Enum.find(
          [:customer, :standard, :oss, :inception],
          &(Atom.to_string(&1) == wire["profile"])
        )

      true = not is_nil(profile)
      fields = [:id, :image_id, :pool_id, :slot, :vcpu, :memory_bytes, :disk_bytes]
      shape = Map.new(fields, &{&1, Map.fetch!(wire, Atom.to_string(&1))})
      {:ok, spec} = Spec.new(Map.put(shape, :profile, profile))
      true = spec.id == placement and spec.pool_id == pool.id
      {:ok, _} = Observation.check_state(config.execution, pool, spec, [:running])
      {:ok, boot} = Boot.read(directory)
      {:ok, intent} = Intent.set(directory, placement, {epoch, generation}, :paused)

      authority =
        intent
        |> Map.take([:placement_id, :execution_epoch, :generation])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

      {:ok, compatibility} = Checkpoint.compatibility(config.execution.firecracker)
      {:ok, _} = Checkpoint.begin_capture(pool, spec, boot, authority, compatibility)
      :ok = API.pause(Path.join(Jail.root(pool, spec), "api.sock"))
      {:ok, _} = Observation.check_state(config.execution, pool, spec, [:paused])

      {:ok, %{"phase" => "capturing", "descriptor" => nil, "capture_authority" => ^authority}} =
        Checkpoint.read(pool, placement)

      true =
        Enum.all?(["a", "b"], fn slot ->
          root = Path.join([pool.path, ".lilly-checkpoints", placement, slot, "output"])

          not File.exists?(Path.join(root, "memory")) and
            not File.exists?(Path.join(root, "state"))
        end)

      :ok
    after
      Lilly.Host.Lock.release(lock)
    end
  end

  def run(action, placement, peer) do
    Process.put(:fixture_stage, :connect)
    true = OverallsProtocol.uuid?(placement)
    if peer != nil, do: true = OverallsProtocol.uuid?(peer)
    if action == "clone-check", do: true = peer != nil and peer != placement
    {:ok, socket} = Terminal.connect(placement)

    try do
      Process.put(:fixture_stage, :prompt)

      :ok = Terminal.ready(socket, 120_000)

      case action do
        "memory-prepare" ->
          # @cc [owner:ghuntley,label:verification] suspension-ram-process-oracle
          # The nonce MUST originate only in the live process and the reference
          # MUST stay on /run tmpfs. Verification MUST compare its PID, kernel
          # boot UUID and nonce; persisted disk markers cannot satisfy this oracle.
          source = """
          import http.server,json,os
          from pathlib import Path
          identity=json.dumps({"nonce":os.urandom(32).hex(),"pid":os.getpid(),"boot_uuid":Path('/proc/sys/kernel/random/boot_id').read_text().strip()}).encode()
          class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
              self.send_response(200)
              self.end_headers()
              self.wfile.write(identity)
            def log_message(self,*args: object) -> None:
              pass
          http.server.HTTPServer(('127.0.0.1',18765),Handler).serve_forever()
          """

          encoded = Base.encode64(source)

          command(
            socket,
            "systemd-run --unit=memory-continuation --property=Restart=no " <>
              "python3 -c \"import base64;exec(base64.b64decode('#{encoded}'))\""
          )

          command(
            socket,
            "for i in $(seq 1 100); do curl --fail --silent http://127.0.0.1:18765/ > /run/memory-continuation.expected && break; sleep 0.1; done; test -s /run/memory-continuation.expected"
          )

        "memory-verify" ->
          command(
            socket,
            "test -s /run/memory-continuation.expected && curl --fail --silent http://127.0.0.1:18765/ | cmp - /run/memory-continuation.expected && systemctl is-active memory-continuation.service"
          )

        "readiness-diagnostics" ->
          readiness_diagnostics(socket)

        "terminal-diagnostics" ->
          for event <-
                ~w(ssh.account_create_failed ssh.account_lookup_failed ssh.home_lookup_failed ssh.home_permissions_failed ssh.home_ownership_failed ssh.account_state_failed ssh.account_activate_failed ssh.sudo_policy_failed ssh.state_invalid ssh.state_stage_failed ssh.roster_stale ssh.roster_rejected ssh.roster_fetch_failed ssh.authority_timeout ssh.tls_trust_failed ssh.authority_connect_failed ssh.authority_transport_failed ssh.authority_denied ssh.authority_response_too_large ssh.roster_reconciled) do
            present = diagnostic_event(socket, event)
            IO.puts("Guest helper diagnostic: #{event}=#{present}")
          end

        "ubuntu-check" ->
          Process.put(:fixture_stage, :ubuntu_identity)

          command(
            socket,
            ". /etc/os-release && test \"$ID\" = ubuntu && test \"$VERSION_ID\" = 26.04"
          )

          Process.put(:fixture_stage, :ubuntu_dns_egress)

          command(
            socket,
            "test \"$(curl --silent --fail --max-time 10 http://fleet.example.test:8080/)\" = fixture-egress-ok"
          )

          Process.put(:fixture_stage, :ubuntu_protected_destination)

          command(
            socket,
            "curl --silent --connect-timeout 2 --max-time 3 http://11.0.0.2:8080/ -o /dev/null; test \"$?\" = 28"
          )

        "customer-network" ->
          Process.put(:fixture_stage, :customer_network)

          command(
            socket,
            "curl --silent --connect-timeout 2 --max-time 3 http://11.0.0.1:8080/ -o /dev/null; test \"$?\" = 28"
          )

          command(
            socket,
            "curl --silent --connect-timeout 2 --max-time 3 http://fleet.example.test:8080/ -o /dev/null; test \"$?\" = 28"
          )

        "prepare" ->
          Process.put(:fixture_stage, :initial_write)
          command(socket, "printf before-copy > /root/relocation-before && sync")

          Process.put(:fixture_stage, :writer_start)

          command(
            socket,
            "systemd-run --quiet --unit=relocation-writer --setenv=PATH=\"$PATH\" " <>
              "\"$(command -v bash)\" -c 'n=0; while true; do " <>
              "n=$((n+1)); printf %s $n > /root/relocation-counter.new; " <>
              "mv /root/relocation-counter.new /root/relocation-counter; " <>
              "sync; sleep 0.2; done'"
          )

          Process.put(:fixture_stage, :writer_progress)
          command(socket, "until test -s /root/relocation-counter; do sleep 0.1; done")

        "before-stop" ->
          Process.put(:fixture_stage, :pre_stop_write)

          command(
            socket,
            "systemctl is-active --quiet relocation-writer.service && " <>
              "printf before-stop > /root/relocation-after && sync"
          )

        "bulk" ->
          Process.put(:fixture_stage, :bulk_write)

          command(
            socket,
            "dd if=/dev/urandom of=/root/relocation-bulk bs=1M count=128 status=none && " <>
              "sha256sum /root/relocation-bulk > /root/relocation-bulk.sha256 && sync",
            120_000
          )

        "break-readiness" ->
          Process.put(:fixture_stage, :readiness_failure)

          command(
            socket,
            "systemctl stop lilly-readiness.service && " <>
              "! systemctl is-active --quiet lilly-readiness.service"
          )

        "verify-live" ->
          Process.put(:fixture_stage, :live_writer_verification)

          command(
            socket,
            "systemctl is-active --quiet relocation-writer.service && " <>
              "previous=$(cat /root/relocation-counter) && " <>
              "timeout 10 bash -c 'until test \"$(cat /root/relocation-counter)\" -gt \"$1\"; " <>
              "do sleep 0.1; done' _ \"$previous\""
          )

        "verify" ->
          Process.put(:fixture_stage, :data_verification)

          command(
            socket,
            "test \"$(cat /root/relocation-before)\" = before-copy && " <>
              "test \"$(cat /root/relocation-after)\" = before-stop && " <>
              "test \"$(cat /root/relocation-counter)\" -gt 0 && " <>
              "if test -f /root/relocation-bulk.sha256; then " <>
              "sha256sum --status -c /root/relocation-bulk.sha256; fi"
          )

        "clone-cancel-seed" ->
          # @cc [owner:ghuntley,label:verification;recovery] cancellation-native-copy-window
          # Only the disposable guest may receive this fixed 512 MiB witness.
          # Bytes MUST come from guest randomness, be synced before capture and
          # never be emitted. The witness MUST NOT change workflow authority.
          Process.put(:fixture_stage, :clone_cancel_seed)

          command(
            socket,
            "dd if=/dev/urandom of=/root/clone-cancel-window bs=1048576 count=512 status=none && sync",
            120_000
          )

        "clone-write" ->
          Process.put(:fixture_stage, :clone_marker_write)

          command(
            socket,
            "printf %s #{placement} > /root/clone-own-#{placement} && sync"
          )

        "clone-inherit" ->
          Process.put(:fixture_stage, :clone_inherited_check)
          true = peer != nil and peer != placement

          command(
            socket,
            "test \"$(cat /root/clone-own-#{peer})\" = #{peer}"
          )

        "clone-write-post" ->
          Process.put(:fixture_stage, :clone_post_write)

          command(
            socket,
            "printf %s #{placement} > /root/clone-post-#{placement} && sync"
          )

        "clone-check" ->
          Process.put(:fixture_stage, :clone_divergent_check)
          true = peer != nil and peer != placement

          command(
            socket,
            "test \"$(cat /root/clone-post-#{placement})\" = #{placement} && " <>
              "test ! -e /root/clone-post-#{peer}"
          )
      end
    after
      Terminal.close(socket)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] clone-readiness-diagnostic-allowlist
  # Readiness diagnostics MUST emit only activity booleans for these fixed guest
  # units and fixed marker-presence probes. Console bytes and unit environments
  # MUST remain private; diagnostics MUST NOT establish readiness acceptance.
  @spec readiness_diagnostics(Terminal.t()) :: :ok
  defp readiness_diagnostics(socket) do
    probes = [
      {"multi_user", "systemctl is-active --quiet multi-user.target"},
      {"network", "systemctl is-active --quiet lilly-network.service"},
      {"private_dns", "systemctl is-active --quiet lilly-private-dns.service"},
      {"readiness", "systemctl is-active --quiet lilly-readiness.service"},
      {"sshd", "systemctl is-active --quiet sshd.service"},
      {"ssh_sync_failed", "systemctl is-failed --quiet overalls-ssh-sync.service"},
      {"ssh_ready", "test -e /run/overalls-ssh-ready"},
      {"roster", "test -s /var/lib/overalls-ssh/accounts.json"}
    ]

    for {name, probe} <- probes do
      marker = "READY_" <> Base.encode16(:crypto.strong_rand_bytes(12))

      :ok =
        Terminal.write(
          socket,
          "if #{probe}; then printf '\\n%s%s\\n' #{marker} _YES; " <>
            "else printf '\\n%s%s\\n' #{marker} _NO; fi\n"
        )

      passed = diagnostic_result(socket, marker, deadline(10_000), "")
      IO.puts("Guest readiness diagnostic: #{name}=#{passed}")
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] terminal-helper-diagnostic-allowlist
  # Failure diagnostics MUST report only presence booleans for fixed helper
  # events. Guest journal and terminal contents MUST NOT enter test output.
  @spec diagnostic_event(Terminal.t(), String.t()) :: boolean()
  defp diagnostic_event(socket, event) do
    marker = "DIAG_" <> Base.encode16(:crypto.strong_rand_bytes(12))

    :ok =
      Terminal.write(
        socket,
        "since=0; if test -f /run/terminal-diagnostics-since; then " <>
          "read -r since < /run/terminal-diagnostics-since; fi; " <>
          "case $since in ''|*[!0-9]*) since=0;; esac; " <>
          "if journalctl --since=\"@$since\" -t overalls-ssh-authorize -o cat --no-pager | grep -Fq '\"event\":\"#{event}\"'; then " <>
          "printf '\\n%s%s\\n' #{marker} _YES; else printf '\\n%s%s\\n' #{marker} _NO; fi\n"
      )

    diagnostic_result(socket, marker, deadline(10_000), "")
  end

  @spec diagnostic_result(Terminal.t(), String.t(), integer(), binary()) :: boolean()
  defp diagnostic_result(socket, marker, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        cond do
          String.contains?(body, "\n#{marker}_YES\n") ->
            true

          String.contains?(body, "\n#{marker}_NO\n") ->
            false

          true ->
            diagnostic_result(
              socket,
              marker,
              until,
              binary_part(body, max(0, byte_size(body) - 128), min(byte_size(body), 128))
            )
        end

      {:error, :timeout} ->
        diagnostic_result(socket, marker, until, tail)

      _ ->
        raise "Guest diagnostics unavailable"
    end
  end

  defp command(socket, command, timeout \\ 30_000) do
    marker = "MOVE_" <> Base.encode16(:crypto.strong_rand_bytes(12))
    :ok = Terminal.write(socket, command <> " && printf '\\n#{marker}:OK\\n'\n")
    wait(socket, "\n#{marker}:OK\n", deadline(timeout), "")
  end

  defp wait(socket, marker, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(body, marker) == :nomatch do
          count = min(byte_size(body), byte_size(marker))
          wait(socket, marker, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(socket, marker, until, tail)

      _ ->
        raise "Guest console unavailable"
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end

try do
  case System.argv() do
    [action, placement] -> :ok = FleetRelocationGuest.run(action, placement)
    [action, placement, peer] -> :ok = FleetRelocationGuest.run(action, placement, peer)
  end

  IO.puts("Relocation guest assertions passed")
rescue
  error ->
    IO.puts(
      :stderr,
      "Relocation guest assertion failed at #{inspect(Process.get(:fixture_stage, :arguments))} " <>
        "(#{inspect(error.__struct__)}); terminal bytes withheld"
    )

    System.halt(1)
end
