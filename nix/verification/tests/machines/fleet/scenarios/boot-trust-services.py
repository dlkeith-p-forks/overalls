# @cc [owner:ghuntley,label:verification;security] fleet-feature-independent-trust
# Feature-fleet journeys MUST start real DNS and gateway credentials before
# guest admission. Enabling these prerequisites MUST NOT select the Audi feature
# scenario or bypass guest readiness. Enrollment already starts private services.
with subtest("shared guest trust prerequisites precede feature-fleet admission"):
    for machine in (m2, m3):
        path = f"{root}/audi-{machine.name}.token"
        operator(
            m1, dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=path)
        )
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
    for machine in provisioners:
        path = f"{root}/audi-{machine.name}.token"
        address = client.succeed(
            "python3 -c "
            + shlex.quote("import socket; print(socket.gethostbyname(" + repr(machine.name) + "))")
        ).strip()
        operator(
            m1,
            dict(
                action="audi-enroll",
                role="gateway",
                name="audi-" + machine.name,
                host_id=host_bindings[machine.name]["host"],
                addresses=[address],
                output=path,
            ),
        )
        transfer(m1, root + "/audi-root.pem", machine, root + "/audi-root.pem")
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi-private.service")
        machine.wait_for_unit("audi.service")
        machine.wait_for_open_port(22)
