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
      "Relocation guest assertion failed at #{Process.get(:fixture_stage, :arguments)} " <>
        "(#{inspect(error.__struct__)}); terminal bytes withheld"
    )

    System.halt(1)
end
