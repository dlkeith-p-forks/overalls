# Security Policy

Overalls is a self-hosted platform for development machines and the AI agents
that work on them. There is no hosted service: you run it. This policy covers
how to report security problems in the Overalls project and in
[overalls.dev](https://overalls.dev).

The canonical version of this policy is published at
<https://overalls.dev/security/>, with a machine-readable copy at
<https://overalls.dev/.well-known/security.txt>.

## Reporting a vulnerability

**Please don't open a public issue or pull request.**

Report vulnerabilities by opening a
[private security advisory](https://github.com/ghuntley/overalls/security/advisories/new)
on this repository using GitHub's security advisory feature. This is the
preferred way to report, and it keeps the report private until a fix is
disclosed.

If you can't use GitHub, email
[ghuntley@mail.grokbot.com](mailto:ghuntley@mail.grokbot.com) instead, and
encrypt your report with our PGP key if you can.

### PGP key

Fingerprint: `2C54 D2FF 3D44 8408 54AB 2467 478B 677B 185A C53E`

```text
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEatJCrxYJKwYBBAHaRw8BAQdAGB+tuFpzF0NDi3TZxtxl1PC8sDVWGqqSfXZD
7Za9evi0JUdsYXNzd2luZyA8Z2h1bnRsZXlAbWFpbC5ncm9rYm90LmNvbT6IkAQT
FgoAOBYhBCxU0v89RIQIVKskZ0eLZ3sYWsU+BQJq0kKvAhsDBQsJCAcCBhUKCQgL
AgQWAgMBAh4BAheAAAoJEEeLZ3sYWsU+R/0A/RCsZgiuGgkizl5UBYaOB1Cdwyhf
O/SkxtXlNXilNxGRAP9GUy6gQqpFY87xGOxNiJgeSRevsALJRf1CcUVq1o4jAbg4
BGrSQq8SCisGAQQBl1UBBQEBB0D2aR+ieiRxWR8D+rpz6LMvxj+HwAkUsa7dpsiS
BXOAagMBCAeIeAQYFgoAIBYhBCxU0v89RIQIVKskZ0eLZ3sYWsU+BQJq0kKvAhsM
AAoJEEeLZ3sYWsU+NZgA/AqiKVdgAIiSgjXAFOOzRbdlosgZIrupmSzZ5vWqF2w3
AQCxVQ1uvY3Wgs241obINzuNUOIJaLjmyT3opfCjSdN5Dg==
=d1Do
-----END PGP PUBLIC KEY BLOCK-----
```

Check that the fingerprint of the key you import matches the one above
before you encrypt.

### What to include

- the commit or release you tested
- how it was deployed
- step-by-step reproduction
- what an attacker gains

## What to expect

We'll confirm we've received your report and keep you updated as we
investigate and fix it. We aim to agree a disclosure date with you, normally
within 90 days of the report.

## Scope

In scope:

- The Overalls source code in this repository
- Anything that lets one tenant reach another, such as escaping a guest's
  isolation or crossing between guests, users or access roles
- This website, `overalls.dev`

Out of scope:

- Other people's deployments of Overalls
- Third-party services
- Denial of service
- Scanner output without a working proof of concept

## Supported versions

Overalls is a research preview and doesn't yet publish versioned releases.
Security fixes land on the default branch; please test against the latest
commit before reporting.

## Rewards

Reporters receive public thanks on the
[hall of fame](https://overalls.dev/security/hall-of-fame/) and credit in the
advisory. There is no cash bounty.

## Safe harbour

If you research and report in good faith and follow this policy, we consider
your research authorised. This safe harbour covers only the Overalls project
and `overalls.dev`, not third-party deployments or services.
