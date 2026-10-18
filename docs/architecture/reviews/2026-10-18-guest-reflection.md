# Guest reflection architecture review

The change adds the Peach private service and a protocol projection. It keeps
authorization and dedicated credential persistence in Marshall, routing in Audi,
and execution policy in Lilly. Peach has no database authority. The projection is fenced by VM,
placement, execution epoch, host, and completed start operation, and redacts
header values and credentials.

Implementation is partial. The NixOS module packages Peach with systemd credential
custody, but the declared fleet does not enable it. Marshall owns the dedicated
host credential, digest-only storage, rotation/revocation and secret-free
PaperTrail versions; ordinary users cannot access either credential resource.
The credential lifecycle tests and protocol property tests are present. No
recorded execution result is claimed here. Peach's current HTTP-named test only
validates a projection fixture through the codec and does not invoke the Plug.
Successful packaged guest projection, execution/expiry histories, native
isolation and cross-host recovery remain unverified.
