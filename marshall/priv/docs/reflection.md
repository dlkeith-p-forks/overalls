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

## Metadata controls

Machine managers can edit labels and the machine comment from machine settings.
Labels are limited to 32 entries and comments to 2 KiB. Integration managers
can edit an integration comment from the integrations page. Changes are
audited without recording comment text or secret values.

Reflection is available only through the private network. Requests are bound to
the current VM, host, placement, and execution epoch; stopped, relocated,
retired, stale, or unauthorized guests receive an unavailable response.
