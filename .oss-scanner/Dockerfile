# Offline-analysis image for Anthropic OSS Scanner.
#
# The scanner supplies the repository as the build context and audits the
# resulting image without Internet access. Keep the source tree, Git history,
# pinned Nix inputs, dependency closures and release outputs in the image so a
# report can reproduce a finding without contacting an external service.
#
# Stages are ordered so the slowest work stays cached: the Nix installation
# changes only with this file, the pinned flake inputs only with flake.lock,
# and only the release build reruns for ordinary source changes.

FROM debian:bookworm AS base

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

# The build users the single-user installation expects. The final stage keeps
# them so the copied store's ownership and the scanner's later Nix use agree.
RUN groupadd --system nixbld \
    && for builder in $(seq 1 10); do \
         useradd --system --no-create-home --gid nixbld "nixbld${builder}"; \
         usermod --append --groups nixbld "nixbld${builder}"; \
       done

FROM base AS nix

# Install a single-user Nix profile. The scanner's later layer supplies the
# package manager, compilers and debugger tools it uses during analysis.
RUN mkdir -m 0755 /nix \
    && curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install \
    | sh -s -- --no-daemon \
    && nix --version

FROM nix AS inputs

# Fetch every pinned flake input from the lock alone, so this layer is reused
# until flake.nix or flake.lock changes.
WORKDIR /src
COPY flake.nix flake.lock /src/
RUN nix flake archive --no-write-lock-file

FROM inputs AS build

COPY . /src

# Build the primary control-plane release. The repository's Nix checks cover
# the other non-inception releases; inception guest workloads remain excluded.
# The overalls cache serves closures CI already built; the image content is
# the same with or without it.
RUN nix build --no-link --print-build-logs \
      --extra-substituters https://overalls.cachix.org \
      --extra-trusted-public-keys overalls.cachix.org-1:ngFF/lz1uZK7apXZuS1j7lJcc7hJfjdGatNrFxu4Sso= \
      .#marshall \
    && nix path-info .#marshall

FROM base

# /root carries the Nix profile and ~/.cache/nix, whose fetcher cache maps the
# locked inputs to their store paths so the flake evaluates offline.
COPY --from=build /nix /nix
COPY --from=build /root /root
COPY --from=build /src /src

# Leave a small, deterministic assertion that the image contains the source,
# history and compiled release closures needed by an offline auditor.
WORKDIR /src
RUN set -eu; \
    nix --version; \
    test -d /src/.git; \
    git -C /src log -1 --format=%H; \
    test -f /src/flake.lock; \
    test -x "$(nix path-info .#marshall)/bin/marshall"

ENTRYPOINT []
CMD ["bash"]
