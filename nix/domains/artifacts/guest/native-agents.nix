{ pkgs, lyra }:
let
  # @cc [owner:ghuntley,label:security] native-agent-set-complete
  # Every binary listed here MUST be cross-built for the selected native OS;
  # the image builder MUST never copy the Linux Lyra closure into a native
  # root. Probe and trust listeners MUST start before roster/certificate
  # bootstrap; readiness MUST remain false until the complete live service set,
  # including sshd, exists on the host-only vsock channel.
  binaries = [
    "overalls-native-kernel-probed"
    "overalls-native-agentd"
    "overalls-native-flushd"
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
    "overalls-ssh-authorize"
    "overalls-host-certificate"
  ];
  # @cc [owner:ghuntley,label:verification;recovery] native-supervisor-process-markers
  # Each supervised daemon MUST publish its child PID as decimal digits and one
  # newline under /var/run/overalls, remove the marker when reaping that child,
  # and restart unexpected exits. Readiness MUST also check that the PID lives;
  # marker presence alone is insufficient. Supervisor shutdown MUST terminate
  # its watchers and their daemon children.
  supervised = [
    "overalls-native-kernel-probed"
    "overalls-native-agentd"
    "overalls-native-flushd"
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
  ];
  copy = os: assert builtins.elem os [ "freebsd" "illumos" ]; pkgs.runCommand "overalls-${os}-guest-agent-binaries" { } ''
    mkdir -p "$out/bin"
    ${pkgs.lib.concatMapStringsSep "\n" (binary: ''
      install -D -m 0755 ${lyra}/bin/x86_64-unknown-${if os == "freebsd" then "freebsd" else "illumos"}-${binary} "$out/bin/${binary}"
    '') binaries}
  '';
  freebsdBinaries = copy "freebsd";
  illumosBinaries = copy "illumos";
  freebsdRc = pkgs.writeText "overalls-native-agents-freebsd.rc" ''
    # The rc.d supervisor is enabled only after the image's network bootstrap.
    overalls_native_agents_enable="YES"
  '';
  illumosManifest = pkgs.writeText "overalls-native-agents-illumos.xml" ''
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="manifest" name="overalls-native-agents">
      <service name="site/overalls-native-agents" type="service" version="1">
        <create_default_instance enabled="true"/>
        <single_instance/>
        <dependency name="network" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/network/physical:default"/>
        </dependency>
        <dependency name="multi-user" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/milestone/multi-user:default"/>
        </dependency>
        <exec_method type="method" name="start" exec="/opt/overalls/libexec/native-agents-start" timeout_seconds="30"/>
        <exec_method type="method" name="stop" exec=":kill" timeout_seconds="30"/>
        <stability value="Uncommitted"/>
        <template>
          <common_name><loctext xml:lang="C">Overalls native guest agents</loctext></common_name>
        </template>
      </service>
    </service_bundle>
  '';
  # The shell is intentionally a small supervisor rather than a collection of
  # background jobs. Each child has a volatile PID marker consumed by the
  # readiness probe, is restarted after an unexpected exit, and is terminated
  # together with the supervisor. SSH is part of the declared capability set;
  # roster/certificate or sshd failure therefore fails service startup and
  # withholds readiness instead of being hidden by an ignored exit status.
  supervisor = os: let
    # Native roots do not contain the Linux builder's Nix store or shell.
    binariesPath = if os == "freebsd" then "/usr/local/libexec" else "/opt/overalls/libexec";
    sshd = if os == "freebsd" then "/usr/sbin/sshd" else "/usr/lib/ssh/sshd";
    sshdConfig = if os == "freebsd" then "" else "-f /etc/ssh/sshd_config";
  in pkgs.writeTextFile {
    name = "overalls-native-agents-${os}-supervisor";
    executable = true;
    text = ''
    #!/bin/sh
    set -eu
    run_dir=/var/run/overalls
    stop_file="$run_dir/agents.stop"
    mkdir -p "$run_dir"
    rm -f "$stop_file" "$run_dir/ssh-ready"
    supervisor_pids=""
    cleaned=0

    cleanup() {
      if [ "$cleaned" -eq 1 ]; then
        return
      fi
      cleaned=1
      : > "$stop_file"
      for child in $supervisor_pids; do
        if kill "$child" 2>/dev/null; then
          :
        fi
      done
      for child in $supervisor_pids; do
        if wait "$child" 2>/dev/null; then
          :
        fi
      done
      rm -f "$stop_file" "$run_dir"/*.pid "$run_dir/ssh-ready"
    }
    trap cleanup EXIT
    trap 'exit 0' HUP INT TERM

    supervise() {
      service_name="$1"
      shift
      child=""
      stop_child() {
        if [ -n "$child" ]; then
          if kill "$child" 2>/dev/null; then :; fi
          if wait "$child" 2>/dev/null; then :; fi
        fi
        rm -f "$run_dir/$service_name.pid"
      }
      trap stop_child EXIT
      trap 'exit 0' HUP INT TERM
      while [ ! -e "$stop_file" ]; do
        "$@" &
        child=$!
        printf '%s\n' "$child" > "$run_dir/$service_name.pid"
        if wait "$child"; then
          :
        fi
        rm -f "$run_dir/$service_name.pid"
        if [ ! -e "$stop_file" ]; then
          sleep 1
        fi
      done
    }

    # Probe and trust listeners must exist before SSH bootstrap: the host
    # delivers the CA through trustd, and the roster fetch depends on that CA.
    # Readiness remains false because its complete live-process set includes
    # sshd, whose marker does not exist until these prerequisites pass.
    ${pkgs.lib.concatMapStringsSep "\n" (binary: ''
    supervise ${binary} ${binariesPath}/${binary} &
    supervisor_pids="$supervisor_pids $!"
    '') supervised}

    ssh_bootstrap_ready=0
    ssh_attempt=0
    while [ "$ssh_attempt" -lt 30 ] && [ ! -e "$stop_file" ]; do
      if ${binariesPath}/overalls-ssh-authorize sync >/dev/null 2>&1 &&
         ${binariesPath}/overalls-host-certificate >/dev/null 2>&1 &&
         ${sshd} -t ${sshdConfig} >/dev/null 2>&1; then
        ssh_bootstrap_ready=1
        break
      fi
      ssh_attempt=$((ssh_attempt + 1))
      sleep 1
    done
    if [ "$ssh_bootstrap_ready" -ne 1 ]; then
      # EXIT cleanup stops every listener. rc.d/SMF may then retry the entire
      # bounded attempt without claiming readiness from a partial service set.
      exit 1
    fi

    supervise sshd ${sshd} -D ${sshdConfig} &
    supervisor_pids="$supervisor_pids $!"

    # Keep the parent in the foreground for rc.d and svc.startd. The process
    # markers are health evidence, not readiness by themselves; the native
    # readiness daemon checks that every marker still names a live process.
    while [ ! -e "$stop_file" ]; do
      sleep 1
    done
    '';
  };
  freebsdSupervisor = supervisor "freebsd";
  illumosSupervisor = supervisor "illumos";
  freebsdService = pkgs.writeTextFile {
    name = "overalls-native-agents-freebsd";
    executable = true;
    text = ''
    #!/bin/sh
    # PROVIDE: overalls_native_agents
    # REQUIRE: NETWORKING netif routing
    # KEYWORD: shutdown
    . /etc/rc.subr
    name=overalls_native_agents
    rcvar=overalls_native_agents_enable
    load_rc_config "$name"
    : ''${overalls_native_agents_enable:=NO}
    pidfile=/var/run/overalls/native-agents-supervisor.pid
    command=/usr/sbin/daemon
    command_args="-p $pidfile -r -R 2 -- /usr/local/libexec/native-agents-supervisor"
    run_rc_command "$1"
    '';
  };
  illumosService = pkgs.writeTextFile {
    name = "overalls-native-agents-start";
    executable = true;
    text = ''
    #!/bin/sh
    # SMF retains the child in its service contract after the start method exits.
    /opt/overalls/libexec/native-agents-supervisor &
    exit 0
    '';
  };
  freebsd = pkgs.runCommand "overalls-freebsd-guest-agents" {} ''
    mkdir -p "$out/bin" "$out/usr/local/libexec" "$out/etc/rc.d" "$out/etc/rc.conf.d"
    cp -a ${freebsdBinaries}/bin/. "$out/bin/"
    cp -a ${freebsdBinaries}/bin/. "$out/usr/local/libexec/"
    install -m 0755 ${freebsdSupervisor} "$out/usr/local/libexec/native-agents-supervisor"
    install -m 0755 ${freebsdService} "$out/etc/rc.d/overalls-native-agents"
    install -m 0644 ${freebsdRc} "$out/etc/rc.conf.d/overalls-native-agents"
  '';
  illumos = pkgs.runCommand "overalls-illumos-guest-agents" {} ''
    mkdir -p "$out/bin" "$out/lib/svc/manifest/site" "$out/opt/overalls/libexec"
    cp -a ${illumosBinaries}/bin/. "$out/bin/"
    cp -a ${illumosBinaries}/bin/. "$out/opt/overalls/libexec/"
    install -m 0755 ${illumosSupervisor} "$out/opt/overalls/libexec/native-agents-supervisor"
    install -m 0644 ${illumosManifest} "$out/lib/svc/manifest/site/overalls-native-agents.xml"
    install -m 0755 ${illumosService} "$out/opt/overalls/libexec/native-agents-start"
  '';
in
{
  inherit freebsd illumos freebsdRc freebsdService illumosManifest illumosService freebsdSupervisor illumosSupervisor;
  manifest = {
    version = 1;
    agents = binaries;
    # Terminal support is deliberately omitted until a FreeBSD/illumos
    # terminald target is built and exercised. Keep the native capability row
    # fail-closed rather than letting the presence of the other daemons imply
    # an unimplemented PTY service.
    capabilities = [ "readiness" "trust" "workspace" "flush" "ssh" "agents" ];
  };
}
