{ platform ? "hetzner", firmware ? "uefi" }:
let
  disk = id: serial: kind: {
    inherit id serial kind; device = "/dev/disk/by-id/virtio-${serial}";
    aliases = [ "/dev/disk/by-id/virtio-${serial}" ]; path = "/dev/vda";
    model = "fixture"; transport = "virtio"; size = 12884901888; active = false;
  };
  mirror = platform == "hetzner";
in {
  name = "fixture-${platform}-${firmware}"; reviewed = true; inherit platform firmware;
  inventory = { arch = "x86_64"; machine = "fixture-machine";
    disks = if mirror then [ (disk "primary" "member0" "physical") (disk "secondary" "member1" "physical") ]
      else [ (disk "root" "member0" "ebs") (disk "local1" "member1" "local-nvme") (disk "local2" "member2" "local-nvme") ];
  };
  identity = { hostId = "4b697474"; sshKeys = []; };
  network."10-uplink" = { matchConfig.Name = "en* eth*"; networkConfig.DHCP = "yes"; };
  storage = { system = if mirror then [ "primary" "secondary" ] else [ "root" ];
    guests = if mirror then [] else [ "local1" "local2" ]; quotaBytes = if mirror then 536870912 else null; ashift = 12; };
  budgets = { arcMaxMiB = 512; guestMemoryMiB = 1024; guestCpuCores = 1; };
  git = { repository = "ssh://git@github.com/antithesishq/kittens"; knownHosts = ""; };
  credentials = [];
}
