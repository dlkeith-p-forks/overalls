{ pkgs }:
pkgs.fluent-bit.overrideAttrs (old: {
  patches = (old.patches or []) ++ [ ./journal-checkpoint.patch ./backlog-routing.patch ./metric-storage.patch ./cloudwatch-rejections.patch ./cloudwatch-tls.patch ./explicit-aws-identity.patch ];
})
