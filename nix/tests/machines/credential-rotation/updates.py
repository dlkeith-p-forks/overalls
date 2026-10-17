"""Candidate staging/migration checks after the coordinated rotation scenarios."""

import time

update_inputs = {machine.name: update_repository(machine) for machine in marshalls}

with subtest("independent hosts stage secrets and run real concurrent migrations before switching"):
    revisions = {}
    for machine in marshalls:
        repo, candidates = update_inputs[machine.name]
        revisions[machine.name] = update_publish(machine, repo, candidates["updated"], "updated")
    # Start actual services concurrently; serialize access to each machine's
    # interactive test channel, which is not safe to share between threads.
    for machine in marshalls:
        machine.succeed("systemctl start --no-block overalls-auto-update.service")
    deadline = time.monotonic() + 120
    while True:
        states = [update_status(machine) for machine in marshalls]
        assert all(not state.get("failure") for state in states), states
        if all(state.get("phase") == "migrate" for state in states):
            break
        assert time.monotonic() < deadline, "migrators did not converge"
        time.sleep(0.2)
    db.wait_until_succeeds(
        "sudo -u postgres psql -d marshall -Atc \"SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE a.application_name='marshall:deployment-migration' AND l.locktype='advisory' AND l.granted\" | grep -qx 1",
        timeout=30,
    )
    assert update_status(m1)["phase"] == "migrate"
    m1.succeed(f"cp {root}/marshall.enc.json {root}/during-migration.enc.json")
    # Activation must publish the validated snapshot, even if external
    # delivery replaces its encrypted source while migration is blocked.
    m1.succeed(f"printf invalid > {root}/marshall.enc.json")
    for machine in marshalls:
        machine.wait_until_succeeds(
            "test $(systemctl show -p ActiveState --value overalls-auto-update.service) != activating",
            timeout=300,
        )
        assert update_status(machine)["phase"] == "healthy", update_status(machine)
        machine.succeed(
            "test $(systemctl show -p Result --value overalls-auto-update.service) = success"
        )
    m1.succeed(f"mv {root}/during-migration.enc.json {root}/marshall.enc.json")
    assert (
        db.succeed(
            "sudo -u postgres psql -d marshall -Atc 'SELECT count(*) FROM updater_fixture'"
        ).strip()
        == "1"
    )
    for machine in marshalls:
        ready(machine)
        assert update_status(machine)["lastHealthy"]["revision"] == revisions[machine.name]
        machine.succeed("test ! -e /run/overalls-auto-update/handoff.json")
        machine.succeed("test ! -d /run/overalls-auto-update/staging")

with subtest("a failing candidate migration leaves the serving generation unchanged"):
    repo, candidates = update_inputs[m1.name]
    before = m1.succeed("readlink /run/current-system").strip()
    previous_pid = m1.succeed("systemctl show -p MainPID --value marshall-m1.service").strip()
    update_publish(m1, repo, candidates["broken"], "broken-migration")
    m1.fail("systemctl start overalls-auto-update.service", timeout=240)
    assert update_status(m1)["failedPhase"] == "migrate"
    assert m1.succeed("readlink /run/current-system").strip() == before
    assert (
        m1.succeed("systemctl show -p MainPID --value marshall-m1.service").strip() == previous_pid
    )
    ready(m1)

with subtest("missing candidate secret values fail before changing live bundles"):
    # Keep plaintext inside the fixture, even when staging or migration fails.
    m1.succeed(f"cp {root}/marshall.enc.json {root}/update-original.enc.json")
    m1.succeed(f"printf invalid > {root}/marshall.enc.json")
    update_publish(m1, repo, candidates["updated"], "bad-secret")
    m1.fail("systemctl start overalls-auto-update.service", timeout=240)
    assert update_status(m1)["failedPhase"] == "stage"
    assert (
        m1.succeed("systemctl show -p MainPID --value marshall-m1.service").strip() == previous_pid
    )
    m1.succeed(f"mv {root}/update-original.enc.json {root}/marshall.enc.json")
    update_publish(m1, repo, candidates["updated"], "repaired-secret")
    update_success(m1)
    ready(m1)

with subtest("authority changes and Cloak promotion are rejected before consumers stop"):
    db.succeed(f"cp {root}/rotation-values.json {root}/update-baseline.json")
    for field in ["DATABASE_URL", "TOKEN_SIGNING_SECRET", "SECRET_KEY_BASE", "update-promote"]:
        db.succeed(f"cp {root}/update-baseline.json {root}/rotation-values.json")
        db.succeed("rotation-fixture seal " + field)
        deliver(m1)
        previous_pid = m1.succeed("systemctl show -p MainPID --value marshall-m1.service").strip()
        update_publish(m1, repo, candidates["updated"], field)
        m1.fail("systemctl start overalls-auto-update.service", timeout=240)
        assert update_status(m1)["failure"] == "coordinated_secret_change"
        assert (
            m1.succeed("systemctl show -p MainPID --value marshall-m1.service").strip()
            == previous_pid
        )
        ready(m1)

with subtest("a compatible encrypted key addition restarts consumers with the same release"):
    db.succeed(f"cp {root}/update-baseline.json {root}/rotation-values.json")
    db.succeed("rotation-fixture seal update-add")
    deliver(m1)
    old_release = m1.succeed(
        "systemctl show -p WorkingDirectory --value marshall-m1.service"
    ).strip()
    update_publish(m1, repo, candidates["updated"], "compatible-secret-only")
    update_success(m1)
    assert (
        m1.succeed("systemctl show -p WorkingDirectory --value marshall-m1.service").strip()
        == old_release
    )
    assert (
        m1.succeed("systemctl show -p MainPID --value marshall-m1.service").strip() != previous_pid
    )
    ready(m1)
    check_state("state-cutover")
