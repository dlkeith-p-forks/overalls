# Default OSS machine creation

## Scope and decision fit

Marshall's browser creation form and Porsche-backed SSH `new` command previously
selected Customer when no profile was supplied. Both now select OSS. The user
explicitly requested this default for web and Porsche SSH creation. Explicit
profile choices retain their existing meaning, including Customer's restricted
network and owner-only access.

This changes the profile presented at the two user entry points, not Ash
admission, the persisted VM profile, Lilly's profile enforcement, or Porsche's
transport boundary. [ADR-0046](../decisions/0046-porsche-ssh-management.md)
continues to place machine mutations in Marshall; Porsche forwards the parsed
command over its authenticated API. [ADR-0064](../decisions/0064-customer-workspace-isolation.md)
and [ADR-0103](../decisions/0103-profile-scoped-agent-capabilities.md) still
govern Customer isolation and OSS agent capabilities. No accepted ADR requires
Customer to be the creation default, so none is superseded or amended.

## Review and evidence

The default is resolved before `Compute.provision`, then pinned in the VM and
SSH request receipt. Replay continues to use the existing request identity;
previously created machines keep their profile. Browser URL drafts and explicit
SSH `--profile` values retain the user's choice. Tests inspect the rendered
browser selection and the persisted profile after both paths, including an
explicit Customer SSH request.

OSS permits outbound networking, sharing, web exposure and more agent tools
than Customer. The form's profile descriptions and public Porsche command
reference expose that difference. Admission and host enforcement continue to
use the persisted profile; this review found no bypass of their existing checks.

Validation: focused Marshall browser and SSH tests, Marshall precommit,
contract format/discovery, ADR and HLDD checks are recorded in the change
summary. Native browser/Porsche creation with omitted profile has not been run;
the handbook scenario records that gap separately from existing profile
isolation acceptance.
