# Guest reflection architecture review

The change adds the Peach private service and a protocol projection. It keeps
authorization in Marshall, routing in Audi, and execution policy in Lilly;
there is no new persistence authority. The projection is fenced by VM,
placement, execution epoch, host, and completed start operation, and redacts
header values and credentials.

Implementation is partial pending packaged Peach deployment and a NixOS guest
journey test. The protocol property test is present; native isolation and
cross-host recovery are outside this review's evidence.
