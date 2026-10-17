# @cc [owner:ghuntley,label:verification;security] fleet-lilly-socket-custody
# With guests running, the unprivileged Lilly BEAM's socket descriptor count
# MUST stay flat across a minute of reconciliation (ADR-0184): every jail and
# ingress socket Lilly uses is one it created and closes. A leak of one
# descriptor per API or vsock dial grows the count by dozens in that window.
with subtest("unprivileged Lilly releases every socket it uses"):

    def lilly_sockets(machine: MachineLike) -> int:
        pid = machine.succeed("systemctl show -p MainPID --value lilly.service").strip()
        return int(machine.succeed(f"find /proc/{pid}/fd -lname 'socket:*' | wc -l").strip())

    for machine in provisioners:
        samples = [lilly_sockets(machine)]
        for _ in range(6):
            time.sleep(10)
            samples.append(lilly_sockets(machine))
        assert max(samples) - samples[0] <= 8, (machine.name, samples)
