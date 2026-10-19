# Overlay adding dartssh2-overalls: the pub.dev dartssh2 release Mila locks,
# with OpenSSH Ed25519 host certificates and a host key blob callback so Mila
# verifies Porsche's certificate during key exchange (ADR-0227, ADR-0228).
# The external P-256 signer needs no patch: upstream SSHIdentity is async.
final: _prev: {
  dartssh2-overalls = final.applyPatches {
    name = "dartssh2-overalls-4.1.0";
    src = final.fetchzip {
      name = "dartssh2-4.1.0";
      url = "https://pub.dev/api/archives/dartssh2-4.1.0.tar.gz";
      stripRoot = false;
      hash = "sha256-dlovAjNg9XGxh5b+SFUkUteuJFnf687vcYpCD7VP0MI=";
    };
    patches = [ ./patches/dartssh2-host-certificates.patch ];
  };
}
