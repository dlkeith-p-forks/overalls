# @cc [owner:ghuntley,label:verification] candidate-slo-panel-roster
# Every instrumented application candidate MUST have one completion ratio and
# one observed-duration panel. Add a source here only after its fixed-name
# exporter, collector identity, and readiness marker exist.
[
  { service = "brady"; ratio = "brady_candidate_completion"; title = "Brady admitted terminal request"; }
  { service = "galileo"; ratio = "galileo_candidate_completion"; title = "Galileo authorized integration"; }
  { service = "enrico"; ratio = "enrico_candidate_completion"; title = "Enrico mirror refresh"; }
  { service = "porsche"; ratio = "porsche_candidate_dispatch"; title = "Porsche SSH command dispatch"; }
  { service = "ziggy"; ratio = "ziggy_candidate_completion"; title = "Ziggy durable inference"; }
  { service = "audi_private"; ratio = "audi_private_candidate_completion"; title = "Audi bound private request"; }
  { service = "audi_dns"; ratio = "audi_dns_candidate_completion"; title = "Audi authoritative DNS answer"; }
  { service = "marshall_web"; ratio = "marshall_web_candidate_completion"; title = "Marshall browser HTTP completion"; }
  { service = "audi_ssh"; ratio = "audi_ssh_candidate_establishment"; title = "Audi guest SSH establishment"; }
  { service = "underclass_proxy"; ratio = "underclass_proxy_candidate_completion"; title = "Underclass durable proxy completion"; }
  { service = "marshall_ready"; ratio = "marshall_ready_completion"; title = "Marshall durable creation-to-ready"; }
  { service = "lilly_physical"; ratio = "lilly_physical_completion"; title = "Lilly durable physical lifecycle"; }
  { service = "porsche_physical"; ratio = "porsche_physical_completion"; title = "Porsche durable physical command completion"; }
  { service = "porsche_clone"; ratio = "porsche_clone_completion"; title = "Porsche durable clone completion"; }
  { service = "porsche_relocate"; ratio = "porsche_relocate_completion"; title = "Porsche durable relocation completion"; }
  { service = "porsche_retry"; ratio = "porsche_retry_completion"; title = "Porsche durable retry completion"; }
  { service = "porsche_cancel"; ratio = "porsche_cancel_completion"; title = "Porsche durable cancellation completion"; }
  { service = "vscode_browser_nixos"; ratio = "vscode_browser_nixos_completion"; title = "NixOS authenticated browser editor journey"; }
  { service = "vscode_browser_ubuntu"; ratio = "vscode_browser_ubuntu_completion"; title = "Ubuntu authenticated browser editor journey"; }
  { service = "marshall_live"; ratio = "marshall_live_candidate_completion"; title = "Marshall page interaction completion"; }
]
