defmodule Audi.DNS.ServerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias Audi.DNS.{Authority, Directory, Server, Wire}

  @vm "demo-0123456789abcdef0123456789abcdef"

  setup do
    directory = Audi.Test.DNSDirectory.start!([])

    entries = %{
      "vm.apps.example" => %{
        addresses: [{192, 0, 2, 7}, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}],
        expires_at: System.monotonic_time(:millisecond) + 60_000
      }
    }

    :ok = Directory.publish(directory, 4, entries, System.monotonic_time(:millisecond) + 30_000)

    authority = %Authority{
      zone: ["apps", "example"],
      nameservers: [["ns", "example"]],
      mailbox: ["hostmaster", "example"],
      directory: directory
    }

    server = start_supervised!({Server, authority: authority})
    %{directory: directory, authority: authority, port: Server.port(server)}
  end

  test "real UDP and TCP return the same authoritative address with a 20-second TTL", ctx do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, ctx.port, [:binary, active: false, packet: 2])

    on_exit(fn ->
      :gen_udp.close(udp)
      :gen_tcp.close(tcp)
    end)

    packet = query("vm.apps.example", 1)
    :ok = :gen_udp.send(udp, {127, 0, 0, 1}, ctx.port, packet)
    assert {:ok, {_, _, response}} = :gen_udp.recv(udp, 0, 1000)
    :ok = :gen_tcp.send(tcp, packet)
    assert {:ok, ^response} = :gen_tcp.recv(tcp, 0, 1000)
    assert <<42::16, flags::16, 1::16, 1::16, 0::16, 0::16, _::binary>> = response
    assert (flags &&& 0x840F) == 0x8400
    assert (flags &&& 0x0080) == 0
    assert binary_part(response, byte_size(response) - 10, 10) == <<20::32, 4::16, 192, 0, 2, 7>>
    # A second query on the same connection exercises DNS TCP reuse.
    :ok = :gen_tcp.send(tcp, query("vm.apps.example", 28))
    assert {:ok, ipv6} = :gen_tcp.recv(tcp, 0, 1000)
    assert <<42::16, _::16, 1::16, 0::16, 1::16, _::binary>> = ipv6
  end

  test "canonical editor and webview names share only their explicit publication freshness",
       ctx do
    vm = "00000000-0000-4000-8000-000000000001"
    label = OverallsProtocol.EditorName.label(vm, "00000000-0000-4000-8000-000000000002")
    hash = "1" <> String.duplicate("v", 51)

    entries = %{
      ("editor-" <> String.replace(vm, "-", "") <> ".apps.example") => %{
        addresses: [{192, 0, 2, 8}],
        expires_at: System.monotonic_time(:millisecond) + 60_000
      },
      "webview.apps.example" => %{
        addresses: [{192, 0, 2, 9}],
        expires_at: System.monotonic_time(:millisecond) + 60_000
      }
    }

    assert :ok =
             Directory.publish(
               ctx.directory,
               5,
               entries,
               System.monotonic_time(:millisecond) + 30000
             )

    assert {0, 1, 0} = result(query(label <> ".apps.example", 1), ctx)
    assert {0, 1, 0} = result(query(hash <> ".apps.example", 1), ctx)

    assert {3, 0, 1} =
             result(query("e-invalid-" <> String.duplicate("a", 32) <> ".apps.example", 1), ctx)

    assert :ok =
             Directory.publish(ctx.directory, 6, %{}, System.monotonic_time(:millisecond) + 30000)

    assert {3, 0, 1} = result(query(label <> ".apps.example", 1), ctx)
    assert {3, 0, 1} = result(query(hash <> ".apps.example", 1), ctx)
  end

  test "missing names, missing types, outside zones and transfers are distinct", ctx do
    assert {3, 0, 1} = result(query("absent.apps.example", 1), ctx)
    assert {0, 0, 1} = result(query("vm.apps.example", 15), ctx)
    assert {5, 0, 0} = result(query("other.example", 1), ctx)
    assert {5, 0, 0} = result(query("apps.example", 252), ctx)
    assert {0, 1, 0} = result(query("apps.example", 6), ctx)
    assert {0, 1, 0} = result(query("apps.example", 2), ctx)
  end

  # @cc [owner:ghuntley,label:verification] dns-slo-question-partition
  # Generated ordinary in-zone questions MUST be candidate successes when an
  # authoritative NXDOMAIN is produced; out-of-zone and transfer questions
  # MUST stay excluded, independent of UDP or TCP framing.
  property "candidate DNS outcomes distinguish authoritative completion from refusal", ctx do
    check all(
            label <- string(:alphanumeric, min_length: 1, max_length: 20),
            transport <- member_of([:udp, :tcp])
          ) do
      {reply, outcome} =
        Authority.answer_with_outcome(query("#{label}.apps.example", 1), ctx.authority, transport)

      assert is_binary(reply)
      assert outcome == :success

      {_reply, outside} =
        Authority.answer_with_outcome(query("#{label}.else.example", 1), ctx.authority, transport)

      assert outside == :exclude

      {_reply, transfer} =
        Authority.answer_with_outcome(
          query("#{label}.apps.example", 252),
          ctx.authority,
          transport
        )

      assert transfer == :exclude
    end
  end

  test "stale publication produces a counted candidate failure", ctx do
    :ok = Audi.Test.Writer.stop!(ctx.directory)

    {reply, outcome} =
      Authority.answer_with_outcome(query("vm.apps.example", 1), ctx.authority, :udp)

    assert <<42::16, flags::16, _::binary>> = reply
    assert (flags &&& 15) == 2
    assert outcome == :failure
  end

  test "OTP's independent DNS client interoperates over UDP and TCP", ctx do
    for tcp <- [false, true] do
      assert {:ok, message} =
               :inet_res.resolve(~c"vm.apps.example", :in, :a,
                 nameservers: [{{127, 0, 0, 1}, ctx.port}],
                 usevc: tcp,
                 retry: 1,
                 timeout: 1000
               )

      assert [answer] = :inet_dns.msg(message, :anlist)
      assert :inet_dns.rr(answer, :data) == {192, 0, 2, 7}
      assert :inet_dns.rr(answer, :ttl) == 20
    end
  end

  test "alternate names share base addresses over UDP/TCP and disappear with publication", ctx do
    expires = System.monotonic_time(:millisecond) + 30_000
    addresses = [{192, 0, 2, 9}]
    entries = %{"#{@vm}.apps.example" => %{addresses: addresses, expires_at: expires}}
    assert :ok = Directory.publish(ctx.directory, 5, entries, expires)

    for tcp <- [false, true], {type, address} <- Enum.zip([:a], addresses) do
      name = "p3000-#{@vm}.apps.example"

      assert {:ok, message} =
               :inet_res.resolve(String.to_charlist(name), :in, type,
                 nameservers: [{{127, 0, 0, 1}, ctx.port}],
                 usevc: tcp,
                 retry: 1,
                 timeout: 1000
               )

      assert [answer] = :inet_dns.msg(message, :anlist)
      assert :inet_dns.rr(answer, :domain) == String.to_charlist(name)
      assert :inet_dns.rr(answer, :data) == address
      assert :inet_dns.rr(answer, :ttl) == 20
    end

    assert {0, 0, 1} = result(query("p3000-#{@vm}.apps.example", 15), ctx)

    for prefix <- ["p2999", "p10000", "p03000", "p22", "anything", "x.p3000"] do
      assert {3, 0, 1} = result(query("#{prefix}-#{@vm}.apps.example", 1), ctx)
    end

    assert {3, 0, 1} = result(query("p3000.vm.apps.example", 1), ctx)
    assert :ok = Directory.publish(ctx.directory, 6, %{}, expires)
    assert {3, 0, 1} = result(query("p3000-#{@vm}.apps.example", 1), ctx)
    :ok = Audi.Test.Writer.stop!(ctx.directory)
    assert {2, 0, 0} = result(query("p3000-#{@vm}.apps.example", 1), ctx)
  end

  property "only the accepted alternate port interval inherits a base publication", ctx do
    entries = %{
      "#{@vm}.apps.example" => %{
        addresses: [{192, 0, 2, 9}],
        expires_at: System.monotonic_time(:millisecond) + 60_000
      }
    }

    :ok =
      Directory.publish(ctx.directory, 5, entries, System.monotonic_time(:millisecond) + 60_000)

    check all(port <- integer(0..65_535)) do
      actual = result(query("p#{port}-#{@vm}.apps.example", 1), ctx)
      assert actual == if(port in 3000..9999, do: {0, 1, 0}, else: {3, 0, 1})
    end

    for port <- [3000, 9999] do
      assert {0, 1, 0} = result(query("p#{port}-#{@vm}.apps.example", 1), ctx)
    end
  end

  test "DNS-01 proofs work before address publication and expire independently", ctx do
    now = System.monotonic_time(:millisecond)
    name = "_acme-challenge.#{@vm}.apps.example"
    proofs = for byte <- [1, 2], do: Base.url_encode64(:binary.copy(<<byte>>, 32), padding: false)
    entry = %{challenges: proofs, expires_at: now + 30_000}
    assert :ok = Directory.publish(ctx.directory, 5, %{name => entry}, now + 60_000)

    for tcp <- [false, true] do
      assert {:ok, message} =
               :inet_res.resolve(String.to_charlist(name), :in, :txt,
                 nameservers: [{{127, 0, 0, 1}, ctx.port}],
                 usevc: tcp,
                 retry: 1,
                 timeout: 1000
               )

      answers = :inet_dns.msg(message, :anlist)
      assert Enum.map(answers, &(:inet_dns.rr(&1, :data) |> hd() |> List.to_string())) == proofs
      assert Enum.all?(answers, &(:inet_dns.rr(&1, :ttl) == 5))
    end

    assert {0, 0, 1} = result(query(name, 1), ctx)
    assert {0, 1, 0} = result(query(name, 255), ctx)
    assert {0, 0, 1} = result(query("#{@vm}.apps.example", 1), ctx)
    assert {3, 0, 1} = result(query("p3000-#{@vm}.apps.example", 1), ctx)
    assert {3, 0, 1} = result(query("_acme-challenge.p3000.#{@vm}.apps.example", 16), ctx)
    expired = %{entry | expires_at: now - 1}
    assert :ok = Directory.publish(ctx.directory, 6, %{name => expired}, now + 60_000)
    assert {3, 0, 1} = result(query(name, 16), ctx)
    assert {3, 0, 1} = result(query("#{@vm}.apps.example", 1), ctx)
    # Renewing the complete snapshot cannot revive the expired proof.
    assert :ok = Directory.publish(ctx.directory, 6, %{name => expired}, now + 90_000)
    assert {3, 0, 1} = result(query(name, 16), ctx)
    assert {:error, :stale} = Directory.publish(ctx.directory, 5, %{name => entry}, now + 90_000)
  end

  test "nested control and application owners carry bounded addresses and bootstrap proofs",
       ctx do
    now = System.monotonic_time(:millisecond)
    environment = "lab-abcdef0123456789abcdef0123456789"
    control = "control.#{environment}.inception.apps.example"
    app = "#{@vm}.apps.#{environment}.inception.apps.example"
    proof = Base.url_encode64(<<0::256>>, padding: false)

    entries =
      Map.new([control, app], fn name ->
        {"_acme-challenge." <> name, %{challenges: [proof], expires_at: now + 5000}}
      end)

    assert :ok = Directory.publish(ctx.directory, 5, entries, now + 30_000)

    for name <- [control, app] do
      assert {0, 1, 0} = result(query("_acme-challenge." <> name, 16), ctx)
      assert {0, 0, 1} = result(query(name, 1), ctx)
    end

    entries =
      Enum.reduce([control, app], entries, fn name, acc ->
        Map.put(acc, name, %{addresses: [{192, 0, 2, 37}], expires_at: now + 5000})
      end)

    assert :ok = Directory.publish(ctx.directory, 6, entries, now + 30_000)

    for name <- [control, app], tcp <- [false, true] do
      assert {:ok, message} =
               :inet_res.resolve(String.to_charlist(name), :in, :a,
                 nameservers: [{{127, 0, 0, 1}, ctx.port}],
                 usevc: tcp,
                 retry: 1,
                 timeout: 1000
               )

      assert [answer] = :inet_dns.msg(message, :anlist)
      assert :inet_dns.rr(answer, :domain) == String.to_charlist(name)
      assert :inet_dns.rr(answer, :data) == {192, 0, 2, 37}
      assert :inet_dns.rr(answer, :ttl) in 0..5
      assert {0, 0, 1} = result(query(name, 28), ctx)
    end

    for name <- ["p3000." <> control, "p3000." <> app, "arbitrary." <> app, "p22." <> app] do
      assert {3, 0, 1} = result(query(name, 1), ctx)
    end

    expired = Map.new(entries, fn {name, entry} -> {name, %{entry | expires_at: now - 1}} end)
    assert :ok = Directory.publish(ctx.directory, 7, expired, now + 30_000)
    assert {2, 0, 0} = result(query(app, 1), ctx)
    assert {3, 0, 1} = result(query("_acme-challenge." <> control, 16), ctx)
    assert :ok = Directory.publish(ctx.directory, 8, %{}, now + 30_000)
    assert {3, 0, 1} = result(query(control, 1), ctx)
  end

  test "response questions preserve mixed-case labels for DNS case checking", ctx do
    packet = query("Vm.ApPs.ExAmPlE", 1)
    response = Authority.answer(packet, ctx.authority, :udp)
    assert {:ok, message} = :inet_dns.decode(response)
    assert [question] = :inet_dns.msg(message, :qdlist)
    assert :inet_dns.dns_query(question, :domain) == ~c"Vm.ApPs.ExAmPlE"
    assert [_] = :inet_dns.msg(message, :anlist)
  end

  test "empty replica returns SERVFAIL, never a false NXDOMAIN", ctx do
    empty = Audi.Test.DNSDirectory.start!([])

    assert {2, 0, 0} =
             result(query("vm.apps.example", 1), %{
               ctx
               | authority: %{ctx.authority | directory: empty}
             })
  end

  test "out-of-order and expired publications cannot replace valid data", ctx do
    future = System.monotonic_time(:millisecond) + 30_000
    assert {:error, :stale} = Directory.publish(ctx.directory, 3, %{}, future)
    assert {:error, :conflict} = Directory.publish(ctx.directory, 4, %{}, future)
    assert {:error, :stale} = Directory.publish(ctx.directory, 5, %{}, future - 60_000)
    assert {0, 1, 0} = result(query("vm.apps.example", 1), ctx)
    assert :ok = Directory.publish(ctx.directory, 5, %{}, future)
    assert {3, 0, 1} = result(query("vm.apps.example", 1), ctx)
  end

  test "a stopped replica fails closed without taking down the listener", ctx do
    :ok = Audi.Test.Writer.stop!(ctx.directory)
    assert {2, 0, 0} = result(query("vm.apps.example", 1), ctx)
  end

  test "UDP truncation drops whole records and TCP retains the full answer", ctx do
    entries = %{
      "vm.apps.example" => %{
        addresses: for(n <- 1..40, do: {192, 0, 2, n}),
        expires_at: System.monotonic_time(:millisecond) + 60_000
      }
    }

    :ok =
      Directory.publish(ctx.directory, 5, entries, System.monotonic_time(:millisecond) + 30_000)

    packet = query("vm.apps.example", 1)

    assert <<42::16, flags::16, 1::16, 0::16, _::binary>> =
             Authority.answer(packet, ctx.authority, :udp)

    assert (flags &&& 0x0200) != 0

    assert <<42::16, flags::16, 1::16, 40::16, _::binary>> =
             Authority.answer(packet, ctx.authority, :tcp)

    assert (flags &&& 0x0200) == 0
  end

  defp query(name, type),
    do:
      <<42::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16>> <>
        Wire.encode_name(String.split(name, ".")) <> <<type::16, 1::16>>

  defp result(packet, ctx) do
    <<42::16, flags::16, 1::16, answers::16, authority::16, _::binary>> =
      Authority.answer(packet, ctx.authority, :udp)

    {flags &&& 15, answers, authority}
  end
end
