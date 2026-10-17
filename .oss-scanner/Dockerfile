# Offline-analysis image for Anthropic OSS Scanner.
#
# The scanner supplies the repository as the build context and audits the
# resulting image without Internet access. Keep the source tree, Git history,
# pinned Nix inputs, dependency closures and release outputs in the image so a
# report can reproduce a finding without contacting an external service.
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NIX_CONFIG="experimental-features = nix-command flakes\nsandbox = false" \
    PATH=/root/.nix-profile/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        xz-utils \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install a single-user Nix profile. The scanner's later layer supplies the
# package manager, compilers and debugger tools it uses during analysis.
RUN groupadd --system nixbld \
    && for builder in $(seq 1 10); do useradd --system --no-create-home --gid nixbld "nixbld${builder}"; done \
    && mkdir -m 0755 /nix \
    && curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install \
    | sh -s -- --no-daemon \
    && nix --version

WORKDIR /src
COPY . /src

# Build every deployable application release. Inception guest workloads are
# intentionally outside this scanner image; they are separate NixOS fixtures
# with known unrelated failures.
RUN nix build --no-link --print-build-logs \
      .#marshall \
      .#lilly \
      .#audi \
      .#brady \
      .#enrico \
      .#galileo \
      .#porsche \
      .#ziggy \
    && for output in marshall lilly audi brady enrico galileo porsche ziggy; do \
         nix path-info ".#$output"; \
       done

# Leave a small, deterministic assertion that the image contains the source,
# history and compiled release closures needed by an offline auditor.
RUN set -eu; \
    test -d /src/.git; \
    test -f /src/flake.lock; \
    test -x "$(nix path-info .#marshall)/bin/marshall"; \
    test -x "$(nix path-info .#lilly)/bin/lilly"; \
    test -x "$(nix path-info .#audi)/bin/audi"; \
    test -x "$(nix path-info .#brady)/bin/brady"; \
    test -x "$(nix path-info .#enrico)/bin/enrico"; \
    test -x "$(nix path-info .#galileo)/bin/galileo"; \
    test -x "$(nix path-info .#porsche)/bin/porsche"; \
    test -x "$(nix path-info .#ziggy)/bin/ziggy"

WORKDIR /src
ENTRYPOINT []
CMD ["bash"]
