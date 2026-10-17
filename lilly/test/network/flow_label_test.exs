defmodule Lilly.Network.FlowLabelTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Network.{Config, FlowLabel, Guest}
  @host "11111111-1111-4111-8111-111111111111"
  @placement "22222222-2222-4222-8222-222222222222"
  @intent %{placement_id: @placement, execution_epoch: 1, generation: 1, state: :running}

  property "incarnation changes cannot silently reuse a flow label" do
    check all(epoch <- integer(1..1_000_000), generation <- integer(1..1_000_000)) do
      intent = %{@intent | execution_epoch: epoch, generation: generation}
      {:ok, token} = FlowLabel.token(@host, intent)
      assert token =~ ~r/\A[89a-f][0-9a-f]{31}\z/
      assert FlowLabel.token(@host, intent) == {:ok, token}

      for changed <- [
            %{intent | execution_epoch: epoch + 1},
            %{intent | generation: generation + 1},
            %{intent | placement_id: @host}
          ] do
        assert {:ok, different} = FlowLabel.token(@host, changed)
        refute different == token
      end

      refute FlowLabel.token(@placement, intent) == {:ok, token}
    end
  end

  test "owned policy marker rejects changed incarnation, missing tables and ambiguous shape" do
    {:ok, guest} = Guest.new(@placement, :customer, 5)
    {:ok, token} = FlowLabel.token(@host, @intent)

    table = %{
      "table" => %{
        "family" => "inet",
        "name" => guest.guard,
        "comment" => "lilly-flow-v1:" <> token
      }
    }

    chain = %{
      "chain" => %{
        "family" => "inet",
        "table" => guest.guard,
        "name" => "flow_identity",
        "hook" => "prerouting",
        "prio" => -151,
        "policy" => "accept"
      }
    }

    rule = %{"rule" => %{"family" => "inet", "table" => guest.guard, "chain" => "flow_identity"}}
    document = %{"nftables" => [table, chain, rule]}
    assert FlowLabel.current?(document, guest, token)
    {:ok, next} = FlowLabel.token(@host, %{@intent | generation: 2})
    refute FlowLabel.current?(document, guest, next)

    for rows <- [
          [],
          [table, chain],
          [table, chain, rule, rule],
          [table, put_in(chain, ["chain", "prio"], -200), rule]
        ] do
      refute FlowLabel.current?(%{"nftables" => rows}, guest, token)
    end

    refute FlowLabel.current?(nil, guest, token)
  end

  test "enabled policy requires matching launch authority; labels do not replace source guard" do
    proxy = %{"uid" => 991, "http_ports" => [80], "https_ports" => [443], "dns" => ["1.1.1.1"]}
    {:ok, config} = Config.new(@host, "eth0", [], "/var/lib/lilly/network", false, false, proxy)
    {:ok, guest} = Guest.new(@placement, :customer, 5)
    assert {:ok, rules} = FlowLabel.rules(config, guest, @intent)
    assert rules =~ "iifname \"#{guest.tap}\" ip saddr #{guest.address}"
    assert rules =~ "priority -151"
    assert rules =~ "ct status & confirmed == 0"
    assert rules =~ "ct label == (0 & 1) ct label set"
    refute rules =~ "counter accept"

    for invalid <- [
          nil,
          %{@intent | placement_id: @host},
          %{@intent | state: :stopped},
          %{@intent | generation: 0},
          %{@intent | execution_epoch: -1}
        ] do
      assert {:error, :invalid_flow_identity} = FlowLabel.rules(config, guest, invalid)
    end

    assert {:ok, clear} = FlowLabel.rules(%{config | brady: nil}, guest, nil)
    assert clear == FlowLabel.clear(guest)
    refute clear =~ "hook"
  end
end
