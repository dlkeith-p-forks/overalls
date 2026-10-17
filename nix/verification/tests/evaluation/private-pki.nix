{ pkgs }:
let python = pkgs.python3.withPackages (p: [ p.cryptography ]);
in pkgs.runCommand "audi-private-pki-tests" { nativeBuildInputs = [ python ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  mkdir -p audi/priv/private_pki audi/test/private_pki
  cp ${../../../../audi/priv/private_pki}/*.py audi/priv/private_pki/
  cp ${../../../../audi/test/private_pki}/*.py audi/test/private_pki/
  python -m unittest discover -s audi/test/private_pki -v
  touch $out
''
