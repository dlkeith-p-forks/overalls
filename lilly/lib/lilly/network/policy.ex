defmodule Lilly.Network.Policy do
  @moduledoc "Pure nftables programs. Only validated operator and VM identities reach interpolation."
  alias Lilly.Network.{Config, Guest}
  @ingress_mark 0x41554449
  @web_mark 0x41554457
  @editor_mark 0x45444954
  @android_display_mark 0x414E4452
  @brady_mark 0x42524144
  @brady_egress 0x42524145
  @spec brady_mark() :: pos_integer()
  def brady_mark, do: @brady_mark
  @spec brady_egress_mark() :: pos_integer()
  def brady_egress_mark, do: @brady_egress
  @spec ingress_mark(:ssh | :web | :editor) :: pos_integer()
  def ingress_mark(:ssh), do: @ingress_mark
  def ingress_mark(:web), do: @web_mark
  def ingress_mark(:editor), do: @editor_mark
  @spec android_display_mark() :: pos_integer()
  def android_display_mark, do: @android_display_mark
  @spec ingress_mark() :: pos_integer()
  def ingress_mark, do: @ingress_mark
  @non_public ~w(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4)

  # @cc [owner:ghuntley,label:security] host-and-protected-address-denial
  # root/1 MUST deny guest-uplink traffic to the host input chain and blocked destinations, and
  # permit return forwarding only for established/related reply traffic from the configured egress
  # interface.
  @spec root(Config.t()) :: String.t()
  def root(config) do
    filter = config.tag <> "_filter"
    nat = config.tag <> "_nat"

    """
    add table inet #{filter}
    delete table inet #{filter}
    table inet #{filter} {
      #{blocked(config)}
      chain input {
        type filter hook input priority -10; policy accept;
        iifname "#{config.uplink}" counter drop
      }
      chain forward {
        type filter hook forward priority -10; policy accept;
        iifname "#{config.uplink}" ip daddr @blocked counter drop
        iifname "#{config.uplink}" oifname "#{config.egress}" ip saddr 169.254.255.2 ct state { new, established, related } counter accept
        iifname "#{config.uplink}" counter drop
        oifname "#{config.uplink}" iifname "#{config.egress}" ip daddr 169.254.255.2 ct state { established, related } ct direction reply counter accept
        oifname "#{config.uplink}" counter drop
      }
    }
    add table ip #{nat}
    delete table ip #{nat}
    table ip #{nat} {
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "#{config.egress}" ip saddr 169.254.255.2 counter masquerade
      }
    }
    """
  end

  # @cc [owner:ghuntley,label:security] guest-routing-direct-isolation
  # router/1 MUST deny direct TAP-to-TAP forwarding and guest access to private/special/protected
  # forwarded address ranges; registered private services are local INPUT only.
  # Other permitted new guest flows MUST go only to the uplink, with
  # established/related replies returning to TAPs.
  # Customer forwarding MUST be dropped in both directions, including existing
  # connections, before any established-flow exception.
  # ADR-0069 adds local web interception only for egress-enabled profiles.
  @spec router(Config.t()) :: String.t()
  def router(config) do
    """
    add table inet lilly_filter
    delete table inet lilly_filter
    table inet lilly_filter {
      #{blocked(config)}
      #{brady_prerouting(config)}
      chain input { type filter hook input priority filter; policy drop; #{customer_reply(config)} #{customer_private_ssh(config)} iifname "lv*" ip saddr 10.10.0.0/16 counter drop; #{ingress_reply(config)} #{private_input(config)} #{brady_input(config)} }
      chain output { type filter hook output priority filter; policy drop; #{ingress_open(config)} #{customer_private_reply(config)} oifname "lv*" ip daddr 10.10.0.0/16 counter drop; #{private_output(config)} #{brady_output(config)} }
      chain forward {
        type filter hook forward priority filter; policy drop;
        iifname "lv*" ip saddr 10.10.0.0/16 counter drop
        oifname "lv*" ip daddr 10.10.0.0/16 counter drop
        iifname "lv*" ip daddr @blocked counter drop
        #{brady_forward(config)}
        iifname "lv*" oifname "uplink" ip saddr { 10.20.0.0/16, 10.30.0.0/16, 10.40.0.0/16, 10.41.0.0/16 } ct state { new, established, related } counter accept
        iifname "uplink" oifname "lv*" ct state { established, related } ct direction reply counter accept
      }
    }
    add table ip lilly_nat
    delete table ip lilly_nat
    table ip lilly_nat {
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "uplink" ip saddr { 10.20.0.0/16, 10.30.0.0/16, 10.40.0.0/16, 10.41.0.0/16 } counter masquerade
      }
    }
    """
  end

  # @cc [owner:ghuntley,label:security] brady-interception-fail-closed
  # Enabled Brady MUST intercept only admitted guest web ports before NAT, deny
  # protected targets before local delivery, and drop direct forwarding on those
  # ports even when no transparent listener exists. UDP is limited to configured
  # DNS destinations. Proxy upstream and reply exceptions MUST remain separate
  # from Audi ingress marks and MUST NOT permit private or direct guest access.
  defp brady_prerouting(%Config{brady: nil}), do: ""

  defp brady_prerouting(%Config{brady: cfg} = config) do
    """
    chain brady_intercept {
      type filter hook prerouting priority mangle; policy accept;
      iifname "lv*" ip saddr 10.10.0.0/16 return
      iifname "lv*" ct direction reply return
      #{brady_private_bypass(config)}
      iifname "lv*" ip daddr @blocked counter drop
      iifname "lv*" tcp dport { #{Enum.join(cfg["http_ports"], ", ")} } tproxy ip to :15080 meta mark set #{@brady_mark} ct mark set #{@brady_mark} counter accept
      iifname "lv*" tcp dport { #{Enum.join(cfg["https_ports"], ", ")} } tproxy ip to :15443 meta mark set #{@brady_mark} ct mark set #{@brady_mark} counter accept
    }
    """
  end

  # Existing private services keep their dedicated admission path. This return
  # only skips interception; the input chain still enforces their exact policy.
  defp brady_private_bypass(%Config{private_services: true}),
    do:
      "iifname \"lv*\" ip daddr 169.254.254.1 tcp dport { 53, 443 } return; iifname \"lv*\" ip daddr 169.254.254.1 udp dport 53 return;"

  defp brady_private_bypass(_), do: ""

  defp brady_input(%Config{brady: nil}), do: ""

  defp brady_input(_) do
    "iifname \"lv*\" meta mark #{@brady_mark} ct mark #{@brady_mark} meta l4proto tcp counter accept; " <>
      "iifname \"uplink\" ct mark #{@brady_egress} ct state established ct direction reply counter accept;"
  end

  defp brady_output(%Config{brady: nil}), do: ""

  defp brady_output(%Config{brady: cfg}) do
    """
    meta skuid #{cfg["uid"]} ip daddr @blocked oifname "uplink" counter drop;
    meta skuid #{cfg["uid"]} oifname "lv*" ct mark #{@brady_mark} ct state established ct direction reply counter accept;
    meta skuid #{cfg["uid"]} oifname "uplink" meta mark #{@brady_egress} meta l4proto tcp ct state { new, established } ct mark set #{@brady_egress} counter accept;
    meta skuid #{cfg["uid"]} oifname "uplink" ip daddr { #{Enum.join(cfg["dns"], ", ")} } udp dport 53 ct mark set #{@brady_egress} counter accept;
    meta skuid #{cfg["uid"]} oifname "uplink" ip daddr { #{Enum.join(cfg["dns"], ", ")} } tcp dport 53 ct mark set #{@brady_egress} counter accept;
    """
  end

  defp brady_forward(%Config{brady: nil}), do: ""

  defp brady_forward(%Config{brady: cfg}) do
    """
    iifname "lv*" tcp dport { #{Enum.join(cfg["http_ports"] ++ cfg["https_ports"], ", ")} } counter drop
    iifname "lv*" ip daddr { #{Enum.join(cfg["dns"], ", ")} } udp dport 53 oifname "uplink" counter accept
    iifname "lv*" meta l4proto udp counter reject with icmpx type port-unreachable
    """
  end

  # @cc [owner:ghuntley,label:security] marked-local-ingress-services
  # The optional ingress exception MUST allow only locally originated marked
  # SSH-marked TCP to port 22, web-marked TCP to admitted app ports other than
  # 4444 and 5900, Android-display-marked TCP to non-Customer port 5900, and
  # established replies carrying those connection marks. Only Lilly applies the
  # web mark after exact execution admission; the firewall cannot parse HTTP.
  # Customer MUST accept only SSH-marked port-22 and editor-marked port-4444 connections and their established replies;
  # web marks MUST NOT grant Customer access, including existing connections.
  # It MUST NOT relax forwarding, unmarked output, or new guest-to-host traffic.
  defp ingress_open(%Config{ingress: true}),
    do:
      "meta mark #{@ingress_mark} oifname \"lv*\" ip daddr { 10.10.0.0/16, 10.20.0.0/16, 10.30.0.0/16, 10.40.0.0/16, 10.41.0.0/16 } tcp dport 22 ct state { new, established } ct mark set #{@ingress_mark} counter accept; " <>
        "meta mark #{@web_mark} oifname \"lv*\" ip daddr { 10.20.0.0/16, 10.30.0.0/16, 10.40.0.0/16, 10.41.0.0/16 } tcp dport != { 4444, 5900 } ct state { new, established } ct mark set #{@web_mark} counter accept; " <>
        "meta mark #{@editor_mark} oifname \"lv*\" ip daddr { 10.10.0.0/16, 10.20.0.0/16, 10.30.0.0/16, 10.40.0.0/16, 10.41.0.0/16 } tcp dport 4444 ct state { new, established } ct mark set #{@editor_mark} counter accept; " <>
        "meta mark #{@android_display_mark} oifname \"lv*\" ip daddr { 10.20.0.0/16, 10.30.0.0/16, 10.40.0.0/16, 10.41.0.0/16 } tcp dport 5900 ct state { new, established } ct mark set #{@android_display_mark} counter accept;"

  defp ingress_open(_), do: ""

  defp customer_reply(%Config{ingress: true}),
    do:
      "iifname \"lv*\" ip saddr 10.10.0.0/16 tcp sport 22 ct mark #{@ingress_mark} ct state established ct direction reply counter accept; " <>
        "iifname \"lv*\" ip saddr 10.10.0.0/16 tcp sport 4444 ct mark #{@editor_mark} ct state established ct direction reply counter accept;"

  defp customer_reply(_), do: ""

  # Audi restricts Customer sources to ssh.integration.internal after this fixed endpoint.
  defp customer_private_ssh(%Config{private_services: true}),
    do:
      "iifname \"lv*\" ip saddr 10.10.0.0/16 ip daddr 169.254.254.1 tcp dport { 53, 443 } ct state { new, established } counter accept; " <>
        "iifname \"lv*\" ip saddr 10.10.0.0/16 ip daddr 169.254.254.1 udp dport 53 ct state { new, established } counter accept;"

  defp customer_private_ssh(_), do: ""

  defp customer_private_reply(%Config{private_services: true}),
    do:
      "oifname \"lv*\" ip saddr 169.254.254.1 ip daddr 10.10.0.0/16 tcp sport { 53, 443 } ct state established ct direction reply counter accept; " <>
        "oifname \"lv*\" ip saddr 169.254.254.1 ip daddr 10.10.0.0/16 udp sport 53 ct state established ct direction reply counter accept;"

  defp customer_private_reply(_), do: ""

  defp ingress_reply(%Config{ingress: true}),
    do:
      "iifname \"lv*\" meta l4proto tcp ct mark { #{@ingress_mark}, #{@web_mark}, #{@editor_mark}, #{@android_display_mark} } ct state established ct direction reply counter accept;"

  defp ingress_reply(_), do: ""

  # @cc [owner:ghuntley,label:security] tap-source-and-family-guard
  # guard/1 MUST accept only this guest MAC with one of its assigned IPv4 sources, or ARP from that
  # MAC and assigned address to its gateway. Spoofed sources, IPv6 and other EtherTypes must be dropped at TAP
  # ingress.
  @spec guard(Guest.t()) :: String.t()
  def guard(guest) do
    sources = "{ " <> Enum.join(guest.addresses, ", ") <> " }"

    """
    add table netdev #{guest.guard}
    delete table netdev #{guest.guard}
    table netdev #{guest.guard} {
      chain ingress {
        type filter hook ingress device "#{guest.tap}" priority -500; policy drop;
        ether saddr != #{guest.mac} counter drop
        ether type arp arp saddr ether != #{guest.mac} counter drop
        ether type arp arp saddr ip != #{sources} counter drop
        ether type arp arp daddr ip != #{guest.gateway} counter drop
        ether type arp counter accept
        ether type ip ip saddr #{sources} counter accept
        counter drop
      }
    }
    """
  end

  # @cc [owner:ghuntley,label:security] private-service-local-only
  # Customer SSH DNS/TLS exceptions precede the blanket Customer drop;
  # other private-service exceptions follow it.
  # Private service exceptions MUST only admit eligible guest DNS and HTTPS to the fixed
  # namespace address and their established replies; local loopback TLS probes
  # may use only that same fixed address and HTTPS port. No forwarded, host-uplink,
  # sibling, arbitrary local port or unrelated private destination is opened.
  defp private_input(%Config{private_services: true}) do
    "iifname \"lo\" ip saddr 169.254.254.1 ip daddr 169.254.254.1 tcp dport 443 counter accept; " <>
      "iifname \"lo\" ip saddr 169.254.254.1 ip daddr 169.254.254.1 tcp sport 443 ct state established ct direction reply counter accept; " <>
      "iifname \"lv*\" ip daddr 169.254.254.1 tcp dport { 53, 443 } ct state { new, established } counter accept; " <>
      "iifname \"lv*\" ip daddr 169.254.254.1 udp dport 53 ct state { new, established } counter accept;"
  end

  defp private_input(_), do: ""

  defp private_output(%Config{private_services: true}) do
    "oifname \"lo\" ip saddr 169.254.254.1 ip daddr 169.254.254.1 tcp dport 443 counter accept; " <>
      "oifname \"lo\" ip saddr 169.254.254.1 ip daddr 169.254.254.1 tcp sport 443 ct state established ct direction reply counter accept; " <>
      "oifname \"lv*\" ip saddr 169.254.254.1 tcp sport { 53, 443 } ct state established ct direction reply counter accept; " <>
      "oifname \"lv*\" ip saddr 169.254.254.1 udp sport 53 ct state established ct direction reply counter accept;"
  end

  defp private_output(_), do: ""

  defp blocked(config) do
    ranges = Enum.uniq(@non_public ++ config.protected) |> Enum.join(", ")
    "set blocked { type ipv4_addr; flags interval; auto-merge; elements = { #{ranges} }; }"
  end
end
