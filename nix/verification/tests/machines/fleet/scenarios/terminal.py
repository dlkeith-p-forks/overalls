with subtest("verified terminal v2 sessions, sharing and reconnect across three Marshall machines"):
    browser_probe(
        next(
            result
            for result in vms
            if sql(
                "SELECT profile FROM compute_virtual_machines WHERE id='" + result["vm_id"] + "'"
            )
            != "customer"
        )
    )
