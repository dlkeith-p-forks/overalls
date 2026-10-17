{ pkgs, packages }:
# @cc [owner:ghuntley,label:verification] firecracker-patch-unit-tests
# The unit tests introduced or extended by the Overalls Firecracker patches MUST
# run against the patched vmm crate: PVH start info carries the RSDP address,
# the ACPI PM timer advances within 24 bits and refuses partial access, the
# legacy port manager registers the timer, the `hyperv` template installs
# the Hyper-V leaves while relocating the KVM leaves, the CMOS clock encodes
# the host time, a BAR reprogrammed by the guest moves on the MMIO bus together
# with its queue notification ioeventfds, the block and net devices reset
# and re-activate, block requests spanning several descriptors are
# transferred whole by both I/O engines (the upstream parser, engine and
# property tests run again against the changed request shape), and the vsock
# device resolves indirect descriptor tables for RX and TX packets while
# refusing malformed or nested tables. The nixpkgs
# package only
# runs the firecracker and jailer crate tests, so this derivation re-runs cargo
# on the vmm crate with those filters. KVM is needed for the legacy device test.
packages.vmm.overrideAttrs (previous: {
  pname = "firecracker-patch-tests";
  requiredSystemFeatures = [ "kvm" ];
  cargoTestFlags = [ "--package" "vmm" ];
  checkFlags = [
    "test_system_configuration"
    "acpi_pm_timer::tests"
    "test_register_legacy_devices"
    "test_apply_hyperv_leaves"
    "cmos_rtc::tests"
    "bar_tests"
    "test_bar_relocation_follows_config_write"
    "test_bar_relocation_moves_notification_ioevents"
    "test_bar_relocation_defers_until_high_half"
    "test_hotplug_block"
    "test_queue_setup_in_init_status"
    # The net variant of this test needs /dev/net/tun, which the sandbox lacks;
    # it is run outside the sandbox and recorded in the spike review.
    "block::virtio::device::tests::test_reset_returns_interrupt_and_deactivates"
    "test_reset_deactivates_and_allows_reinitialization"
    "test_parse_scatter_gather"
    "test_scatter_gather"
    "test_parse_generic"
    "test_parse_in"
    "test_parse_out"
    "test_parse_flush"
    "test_parse_get_id"
    "test_sync"
    "test_async"
    "parse_random_requests"
    "test_rx_packet_indirect_chain"
    "test_tx_packet_indirect_chain"
    "test_indirect_chain_refusals"
    "test_rx_packet_assembly"
    "test_tx_packet_assembly"
  ];
  doInstallCheck = false;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    echo "vmm patch tests passed" > "$out/result"
    runHook postInstall
  '';
})
