# Docker build context is the repository root. Every local stage consumes a
# Nix-generated, recursive runtime closure staged by build/prepare-contexts.sh.
# There are no package downloads, source compiles, or /nix/store host mounts at
# Docker build or container startup.

FROM scratch AS pg
COPY antithesis/build/contexts/pg/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/opt/kittens/postgresql/bin:/usr/bin:/bin \
    NO_COLOR=1 \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENTRYPOINT ["/opt/kittens/entrypoints/postgres.sh"]

FROM scratch AS marshall
COPY antithesis/build/contexts/marshall/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
COPY antithesis/operator/ /opt/kittens/operator/
ENV PATH=/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/entrypoints/marshall.sh"]

FROM scratch AS lilly
COPY antithesis/build/contexts/lilly/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/opt/kittens/lilly/host-tools/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/entrypoints/lilly.sh"]

FROM scratch AS lilly-guest
COPY antithesis/build/contexts/lilly-guest/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/opt/kittens/lilly/host-tools/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/entrypoints/lilly.sh"]

FROM scratch AS audi
COPY antithesis/build/contexts/audi/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/audi/bin/audi", "start"]

FROM scratch AS porsche
COPY antithesis/build/contexts/porsche/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/opt/kittens/openssh/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/porsche/bin/porsche", "start"]

FROM scratch AS ziggy
COPY antithesis/build/contexts/ziggy/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/ziggy/bin/ziggy", "start"]

FROM scratch AS galileo
COPY antithesis/build/contexts/galileo/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/galileo/bin/galileo", "start"]

FROM scratch AS brady
COPY antithesis/build/contexts/brady/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/brady/bin/brady", "start"]

FROM scratch AS enrico
COPY antithesis/build/contexts/enrico/rootfs/ /
COPY --chmod=0755 antithesis/entrypoints/ /opt/kittens/entrypoints/
ENV PATH=/opt/kittens/enrico-tools/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OVERALLS_ANTITHESIS_WRITER=/opt/antithesis/sdk_writer \
    OVERALLS_ANTITHESIS_STATE_DIR=/var/lib/overalls-antithesis-sdk
ENTRYPOINT ["/opt/kittens/enrico/bin/enrico", "start"]

FROM scratch AS workload
COPY antithesis/build/contexts/workload/rootfs/ /
COPY antithesis/workload/ /opt/kittens-antithesis/workload/
COPY antithesis/control_peer/ /opt/kittens-antithesis/control-peer/
COPY --chmod=0755 antithesis/build/selected-test/v1/ /opt/antithesis/test/v1/
COPY antithesis/build/selected-test/command-manifest.json /opt/kittens-antithesis/command-manifest.json
ENV PATH=/opt/kittens/python/bin:/opt/kittens/control-peer-tools/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONPATH=/opt/kittens-antithesis/workload:/opt/kittens/python-deps/lib/python3.13/site-packages \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "-m", "core.bootstrap"]

FROM scratch AS origin
COPY antithesis/build/contexts/origin/rootfs/ /
COPY antithesis/fixtures/origin/__init__.py /opt/kittens-antithesis/fixtures/origin/__init__.py
COPY antithesis/fixtures/origin/__main__.py /opt/kittens-antithesis/fixtures/origin/__main__.py
COPY antithesis/fixtures/origin/server.py /opt/kittens-antithesis/fixtures/origin/server.py
ENV PATH=/opt/kittens/python/bin:/opt/kittens/git/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONPATH=/opt/kittens-antithesis/fixtures PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "-m", "origin", "serve"]

FROM scratch AS smtp
COPY antithesis/build/contexts/smtp/rootfs/ /
COPY antithesis/fixtures/origin/__init__.py /opt/kittens-antithesis/fixtures/origin/__init__.py
COPY antithesis/fixtures/origin/__main__.py /opt/kittens-antithesis/fixtures/origin/__main__.py
COPY antithesis/fixtures/origin/server.py /opt/kittens-antithesis/fixtures/origin/server.py
COPY antithesis/fixtures/smtp/__init__.py /opt/kittens-antithesis/fixtures/smtp/__init__.py
COPY antithesis/fixtures/smtp/__main__.py /opt/kittens-antithesis/fixtures/smtp/__main__.py
COPY antithesis/fixtures/smtp/server.py /opt/kittens-antithesis/fixtures/smtp/server.py
ENV PATH=/opt/kittens/python/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONPATH=/opt/kittens-antithesis/fixtures PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "-m", "smtp", "serve"]

FROM scratch AS producer-peer
COPY antithesis/build/contexts/producer-peer/rootfs/ /
COPY antithesis/recorder_peer/peer.exs /opt/kittens-antithesis/recorder-peer/peer.exs
ENV PATH=/opt/kittens/producer-tools/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    ERL_FLAGS="+S 4:4" ELIXIR_ERL_OPTIONS="+fnu"
ENTRYPOINT ["/opt/kittens/producer-tools/bin/elixir", "-pa", "/opt/kittens/request-accounting/ebin", "/opt/kittens-antithesis/recorder-peer/peer.exs"]

FROM scratch AS request-recorder
COPY antithesis/build/contexts/request-recorder/rootfs/ /
ENV PATH=/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENTRYPOINT ["/opt/kittens/request-recorder/bin/slo_recorder"]

FROM scratch AS trace-spool
COPY antithesis/build/contexts/trace-spool/rootfs/ /
ENV PATH=/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENTRYPOINT ["/opt/kittens/trace-spool/bin/overalls-trace-spool"]

FROM scratch AS guest-vmm
COPY antithesis/build/contexts/guest-vmm/rootfs/ /
ENV PATH=/opt/kittens/python/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "/opt/kittens/guest-vmm/server.py", "--socket", "/run/overalls-guest-vmm/control.sock", "--witness-socket", "/run/overalls-guest-witness/witness.sock", "--tools", "/opt/kittens/guest-vmm/tools.json", "--state-root", "/var/lib/overalls-tcg", "--socket-root", "/run/overalls-tcg"]

FROM scratch AS router-vmm
COPY antithesis/build/contexts/router-vmm/rootfs/ /
ENV PATH=/opt/kittens/python/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "/opt/kittens/routervm/runner.py"]
CMD ["--config", "/etc/routervm/config.json", "start"]

FROM scratch AS host-vmm
COPY antithesis/build/contexts/host-vmm/rootfs/ /
ENV PATH=/opt/kittens/python/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "/opt/kittens/lilly-hostvm/runner.py", "start", "--config", "/etc/lilly-hostvm/config.json"]

FROM scratch AS private-host-vmm
COPY antithesis/build/contexts/private-host-vmm/rootfs/ /
ENV PATH=/opt/kittens/python/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "/opt/kittens/lilly-hostvm/runner.py", "start", "--config", "/etc/lilly-hostvm/config.json"]

FROM scratch AS recorder-host-vmm
COPY antithesis/build/contexts/recorder-host-vmm/rootfs/ /
ENV PATH=/opt/kittens/python/bin:/usr/bin:/bin NO_COLOR=1 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/kittens/python/bin/python3.13", "/opt/kittens/recorder-hostvm/runner.py", "start", "--config", "/etc/recorder-hostvm/config.json"]
