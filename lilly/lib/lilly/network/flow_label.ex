defmodule Lilly.Network.FlowLabel do
  @moduledoc "Host-owned connection labels bind guest TCP flows to launch incarnations."
  import Bitwise
  alias Lilly.Network.{Config, Guest}
  @maximum 9_223_372_036_854_775_807

  # @cc [owner:ghuntley,label:security] flow-label-execution-binding
  # A label MUST include host, placement, epoch and generation, not merely the
  # reusable guest address. Invalid identities MUST fail before firewall changes.
  @spec token(String.t(), map()) :: {:ok, String.t()} | {:error, :invalid_flow_identity}
  def token(host, %{placement_id: placement, execution_epoch: epoch, generation: generation})
      when is_integer(epoch) and epoch in 1..@maximum and is_integer(generation) and
             generation in 1..@maximum do
    if OverallsProtocol.uuid?(host) and OverallsProtocol.uuid?(placement) do
      <<_::1, hash::bitstring-size(127), _::binary>> =
        :crypto.hash(:sha256, ["lilly-egress-v1", host, placement, <<epoch::64, generation::64>>])

      {:ok, Base.encode16(<<1::1, hash::bitstring>>, case: :lower)}
    else
      {:error, :invalid_flow_identity}
    end
  end

  def token(_, _), do: {:error, :invalid_flow_identity}

  # @cc [owner:ghuntley,label:security] flow-label-never-retags-existing-connection
  # Only an unconfirmed, unlabeled original-direction TCP SYN from the claimed TAP and source
  # may acquire a label. The rule MUST run after conntrack and before TPROXY,
  # without replacing the earlier source/MAC guard or granting packet admission.
  @spec rules(Config.t(), Guest.t(), map() | nil) ::
          {:ok, String.t()} | {:error, :invalid_flow_identity}
  def rules(%Config{brady: nil}, guest, _), do: {:ok, clear(guest)}

  def rules(config, guest, %{placement_id: placement, state: :running} = intent)
      when placement == guest.vm_id do
    with {:ok, label} <- token(config.host_id, intent) do
      {value, ""} = Integer.parse(label, 16)
      bits = for bit <- 0..127, (value &&& 1 <<< bit) != 0, do: bit
      # nft's ct_label literals are bit indices, not numeric masks. The AND of
      # distinct bits expresses an empty label; OR combines the digest bits.
      {:ok,
       clear(guest) <>
         """
         table inet #{guest.guard} {
           comment "lilly-flow-v1:#{label}"
           chain flow_identity {
             type filter hook prerouting priority -151; policy accept;
             iifname "#{guest.tap}" ip saddr #{guest.address} ct direction original ct state new ct status & confirmed == 0 tcp flags & (fin | syn | rst | ack) == syn ct label == (0 & 1) ct label set #{Enum.join(bits, " | ")}
           }
         }
         """}
    end
  end

  def rules(_, _, _), do: {:error, :invalid_flow_identity}

  @doc "Recognize the owned table's policy version, incarnation and shape before avoiding a reload."
  # @cc [owner:ghuntley,label:assumption;recovery] flow-label-owned-policy-marker
  # Only Lilly or trusted root operators may mutate this claimed table. Changes
  # to the generated policy MUST change its version marker. Missing, mismatched
  # or ambiguous table/chain/rule shape MUST require reinstalling the policy.
  @spec current?(term(), Guest.t(), String.t()) :: boolean()
  def current?(%{"nftables" => entries}, guest, token) when is_list(entries) do
    tables = for %{"table" => table} <- entries, do: table
    chains = for %{"chain" => chain} <- entries, do: chain
    rules = for %{"rule" => rule} <- entries, do: rule

    match?(
      [%{"family" => "inet", "name" => name, "comment" => comment}]
      when name == guest.guard and comment == "lilly-flow-v1:" <> token,
      tables
    ) and
      match?(
        [
          %{
            "family" => "inet",
            "table" => table,
            "name" => "flow_identity",
            "hook" => "prerouting",
            "prio" => -151,
            "policy" => "accept"
          }
        ]
        when table == guest.guard,
        chains
      ) and
      match?(
        [%{"family" => "inet", "table" => table, "chain" => "flow_identity"}]
        when table == guest.guard,
        rules
      )
  end

  def current?(_, _, _), do: false

  @spec clear(Guest.t()) :: String.t()
  def clear(guest),
    do: "add table inet #{guest.guard}\ndelete table inet #{guest.guard}\n"
end
