# Based on ghuntley/loom third_party/smtprelay: Grafana v2.2.3, MIT upstream.
{ lib, buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "overalls-smtprelay";
  version = "2.2.3";
  src = fetchFromGitHub {
    owner = "grafana";
    repo = "smtprelay";
    rev = "v${version}";
    hash = "sha256-phQsVH6kEvgyXvaBo7FmyxU8QOKnZKC5XQZhWhAFxE8=";
  };
  vendorHash = "sha256-Y0xKm178PB9CX/SYL0+DG5R9GRJ0eNuIxwTgG9sYYdY=";
  patches = [ ./transport.patch ];
  ldflags = [ "-s" "-w" ];
  env.OTEL_SDK_DISABLED = "true";
  doCheck = true;
  meta = {
    description = "Synchronous SMTP relay with bounded verified upstream delivery";
    homepage = "https://github.com/grafana/smtprelay";
    license = lib.licenses.mit;
    mainProgram = "smtprelay";
  };
}
