# Reflection integration

Every running guest can query `https://reflection.internal` for a bounded,
secret-free description of itself and the private services currently available
to its execution.

## Endpoints

`GET /` returns a versioned object containing `guest`, `integrations`, and the
available paths. `GET /guest` returns only guest metadata. `GET /integrations`
returns the integrations array directly, which makes it convenient for shell
scripts and agents.

Guest metadata includes the machine name and ID, profile, architecture,
operating-system family, vCPU, memory and disk sizes, image identity,
generation, owner email, team name, current Lilly node, labels, and comment.
Operating-system values come from the validated image manifest.

Integration entries describe the internal URL, useful paths, a short `help`
command, a comment, and injected header names and kinds. Header values,
credentials, tokens, and upstream target URLs are never returned. The list
contains Reflection, LLM, and named integrations authorized for this exact
machine execution.

## Examples

Run these commands from inside the guest. The `-sS` flags keep successful
responses quiet while still showing connection errors, and `-H` requests the
JSON representation.

```sh
curl -sS -H 'Accept: application/json' https://reflection.internal/
```

The response is a versioned object. A healthy guest returns HTTP `200` with
`guest`, `integrations`, and `paths` fields:

```json
{
  "version": 1,
  "guest": {"name": "demo", "id": "…", "profile": "linux"},
  "integrations": [{"name": "reflection", "url": "https://reflection.internal"}],
  "paths": ["/", "/guest", "/integrations"]
}
```

Fetch only the guest metadata when an agent does not need integration details:

```sh
curl -sS -H 'Accept: application/json' https://reflection.internal/guest
```

This returns HTTP `200` and a JSON object containing the bounded guest fields
listed above. Fetch the integration list directly for discovery:

```sh
curl -sS -H 'Accept: application/json' https://reflection.internal/integrations
```

An available guest receives HTTP `200` and a JSON array. A stopped, relocated,
retired, stale, or unauthorized guest receives an unavailable response instead
of metadata; callers should treat any non-`2xx` status as a refusal and avoid
retrying against a different machine.

## Metadata controls

Machine managers can edit labels and the machine comment from machine settings.
Labels are limited to 32 entries and comments to 2 KiB. Integration managers
can edit an integration comment from the integrations page. Changes are
audited without recording comment text or secret values.

Reflection is available only through the private network. Requests are bound to
the current VM, host, placement, and execution epoch; stopped, relocated,
retired, stale, or unauthorized guests receive an unavailable response.
