{ pkgs, elixir }:
let
  promotion = import ./. { inherit pkgs elixir; };
  candidate = promotion.publishedCandidate {
    name = "overalls-native-freebsd-14-3-db752667";
    narHash = "sha256-54e0yr58MHMkqAkjbOaLMxXlQyJzGpP8oTbm6sWCUSg=";
  };
  receipt = relative: sha256: { path = "${candidate}/evidence/${relative}"; inherit sha256; };
  approval = {
    version = 1;
    image_id = "sha256:0150b6d1aee0b30892b937eb0566a3dcebf2c5ca4cec75f7a252bd9ae00beac6";
    manifest = builtins.fromJSON (builtins.readFile ../../../../../protocol/priv/native/freebsd-14.3-db752667.json);
    vmm_sha256 = "9815649a9bed84194ca45c5aef4c9307a596c7ffbe1f9f0e881c1ae536226d02";
    assembly = receipt "assembly.json" "a39b77325abf9507284e4dffdbf520af89f69ad09b713ea3a5b8d990c7ee9029";
    scenarios = [
      {
        name = "services";
        service = receipt "services-services.json" "28e4066ba122d28f452ca23ce94e1fcaa3734e6cf8bf34beadc41a4497050247";
        supporting = [
        ];
      }
      {
        name = "growth";
        service = receipt "growth-services.json" "7377084bcf7814fdf73352f75ec4da40439e0d15e3cd21a21e48cd5a97d99822";
        supporting = [
          (receipt "growth/growth-receipt.json" "33bccba4fa62e1ced9b5cb550ea452e5dadc5ab2040882b9a9ddc171a605774f")
        ];
      }
      {
        name = "isolation";
        service = receipt "isolation-services.json" "a8b15ef62c8cdab44a3bbefd7bc9bea39ea2b6c18327bb9dce953052e51679f0";
        supporting = [
          (receipt "isolation/isolation-9373d18e-667e-44e1-a4bf-ea8a51f7b4a4.json" "4d8defad21081d9dbe9d62471e2834a12391827aec3e623824f6439cc7379fc4")
          (receipt "isolation/isolation-c9ab2033-5f97-4008-a0e5-29c4a82229cc.json" "f2d502e7977740d64f5fc455efabb442ae6e20c29b0145d15b2f11c11617913b")
        ];
      }
      {
        name = "recovery";
        service = receipt "recovery-services.json" "d35f2e7142aaee82fff07c38a3d627140fe3649a2424893537d47ace5880cfe3";
        supporting = [
          (receipt "recovery/recovery-2ca7933d-67d4-4d5c-aead-10294063cfff.json" "b4af3f859275965e624466ac2a052a8f9bee54e97e378d95e711ddaa38c76d2b")
          (receipt "recovery/recovery-85b5bbde-5c51-4ad1-887b-2c044295a6c2.json" "dac225319fc231c8e6cb41e4428e77f1a6c325c282c160f026a20017a4ba967e")
        ];
      }
      {
        name = "crash-recovery";
        service = receipt "crash-recovery-services.json" "f69e4df714c9217ebe6dfe82a7d8c9fdc1158083846dfa08a02cb26787643775";
        supporting = [
          (receipt "crash-recovery/crash-recovery-receipt.json" "aef3507aade749c7eaeb563812b367e24e954518132486ea4d3f8dac614ebb5d")
        ];
      }
    ];
  };
in
promotion.promote {
  imageName = "lilly-freebsd-14_3-x86_64-db752667-promoted";
  inherit candidate approval;
}
