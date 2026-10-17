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
    NIX_CONFIG="experimental-features = nix-command flakes" \
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
    && for builder in $(seq 1 10); do \
         useradd --system --no-create-home --gid nixbld "nixbld${builder}"; \
         usermod --append --groups nixbld "nixbld${builder}"; \
       done \
    && mkdir -m 0755 /nix \
    && mkdir -m 0755 /etc/nix \
    && curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install \
    | sh -s -- --no-daemon \
    && printf '%s\n' \
         'substituters = https://cache.nixos.org https://overalls.cachix.org' \
         'trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= overalls.cachix.org-1:ngFF/lz1uZK7apXZuS1j7lJcc7hJfjdGatNrFxu4Sso=' \
         >> /etc/nix/nix.conf \
    && nix --version

WORKDIR /src
COPY . /src

# Build the primary control-plane release. The repository's Nix checks cover
# the other non-inception releases; inception guest workloads remain excluded.
RUN nix build --no-link --print-build-logs \
      .#marshall \
    && nix path-info .#marshall

# Leave a small, deterministic assertion that the image contains the source,
# history and compiled release closures needed by an offline auditor.
RUN set -eu; \
    test -d /src/.git; \
    test -f /src/flake.lock

WORKDIR /src
ENTRYPOINT []
CMD ["bash"]
