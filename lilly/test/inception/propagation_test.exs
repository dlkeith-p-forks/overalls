defmodule Lilly.Inception.PropagationTest do
  use ExUnit.Case, async: true
  alias Lilly.Inception.Propagation
  @id "11111111-1111-4111-8111-111111111111"
  @proof Base.url_encode64(<<0::256>>, padding: false)
  @label "vm-11111111111111111111111111111111"
  @environment "dev-22222222222222222222222222222222"

  test "every actual IPv4 replica must return the exact live authoritative proofs" do
    {first, one} = replica({127, 0, 0, 1}, fn packet -> reply(packet, @proof) end)
    {second, two} = replica({127, 0, 0, 2}, fn packet -> reply(packet, @proof) end)
    result = Propagation.observe(namespace([first, second]), publication(), now() + 3000)
    assert [%{"label" => @label, "proofs" => [@proof], "ttl_ms" => ttl}] = result["records"]
    assert ttl in 1..3000
    assert result["request_id"] == @id

    expected =
      ~c"_acme-challenge.vm-11111111111111111111111111111111.apps.dev-22222222222222222222222222222222.inception.apps.example"

    assert_receive {:question, ^one, ^expected}
    assert_receive {:question, ^two, ^expected}
  end

  test "wrong proofs, non-authoritative replies, expired TTL and mismatched questions fail" do
    for failure <- [:wrong, :non_authoritative, :expired, :wrong_question] do
      {first, _} = replica({127, 0, 0, 1}, fn packet -> reply(packet, @proof) end)

      {second, _} =
        replica({127, 0, 0, 2}, fn packet ->
          response =
            reply(
              packet,
              if(failure == :wrong,
                do: Base.url_encode64(<<1::256>>, padding: false),
                else: @proof
              ),
              if(failure == :expired, do: 0, else: 5)
            )

          case failure do
            :non_authoritative ->
              <<id::16, _::16, rest::binary>> = response
              <<id::16, 0x8000::16, rest::binary>>

            :wrong_question ->
              :binary.replace(response, "_acme-challenge", "_fake-challenge")

            _ ->
              response
          end
        end)

      assert Propagation.observe(namespace([first, second]), publication(), now() + 4000)[
               "records"
             ] == []
    end
  end

  # inception-proof-query-budget: one round shares a 1200ms deadline and each
  # owner task is killed at 1400ms. The stalled replica and the publication
  # lease are both an order of magnitude beyond that budget plus an explicit
  # scheduler tolerance, so the bound separates "capped by the round" from
  # "extended by the replica or lease" even when the host is heavily loaded.
  @round_budget_ms 1400
  @scheduler_tolerance_ms 3600
  @stall_ms 30_000

  test "a stalled replica cannot exceed the shared round deadline" do
    {first, _} = replica({127, 0, 0, 1}, fn packet -> reply(packet, @proof) end)

    {second, stalled} =
      replica({127, 0, 0, 2}, fn _ ->
        Process.sleep(@stall_ms)
        nil
      end)

    started = now()

    assert Propagation.observe(namespace([first, second]), publication(), started + 2 * @stall_ms)[
             "records"
           ] == []

    elapsed = now() - started
    # The stalled replica was actually queried, so the bound below is the
    # round deadline cutting its wait short rather than a skipped query.
    assert_receive {:question, ^stalled, _}, @scheduler_tolerance_ms
    assert elapsed < @round_budget_ms + @scheduler_tolerance_ms
  end

  test "expired publications and invalid operator endpoints produce no queries" do
    {first, id} = replica({127, 0, 0, 1}, fn packet -> reply(packet, @proof) end)
    second = %{first | "name" => "ns2.example", "address" => "::1"}

    assert Propagation.observe(namespace([first, second]), publication(), now() + 4000)["records"] ==
             []

    refute_receive {:question, ^id, _}, 30
    second = %{second | "address" => "127.0.0.2"}

    assert Propagation.observe(namespace([first, second]), publication(), now() - 1)["records"] ==
             []

    refute_receive {:question, ^id, _}, 30
    forged = put_in(publication(), ["records", Access.at(0), "label"], "other.example")
    assert Propagation.observe(namespace([first, second]), forged, now() + 4000)["records"] == []
    refute_receive {:question, ^id, _}, 30
  end

  test "a round covers at most sixteen owners and its cursor reaches deferred owners" do
    {first, _} = replica({127, 0, 0, 1}, fn packet -> reply(packet, @proof) end, 32)
    {second, _} = replica({127, 0, 0, 2}, fn packet -> reply(packet, @proof) end, 32)

    records =
      for number <- 1..17 do
        label =
          "vm-" <>
            (number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0"))

        %{"label" => label, "ready" => false, "proofs" => [@proof]}
      end

    source = %{publication() | "records" => records}
    one = Propagation.observe(namespace([first, second]), source, now() + 5000, 0)
    two = Propagation.observe(namespace([first, second]), source, now() + 5000, 16)
    assert length(one["records"]) == 16
    assert length(two["records"]) == 16

    assert MapSet.new(one["records"] ++ two["records"], & &1["label"]) ==
             MapSet.new(records, & &1["label"])
  end

  test "the control certificate owner cannot be selected as a workload or arbitrary hostname" do
    {first, id} = replica({127, 0, 0, 1}, fn packet -> reply(packet, @proof) end)
    {second, _} = replica({127, 0, 0, 2}, fn packet -> reply(packet, @proof) end)
    source = put_in(publication(), ["records", Access.at(0), "label"], "control")

    assert [%{"label" => "control"}] =
             Propagation.observe(namespace([first, second]), source, now() + 4000)["records"]

    expected =
      ~c"_acme-challenge.control.dev-22222222222222222222222222222222.inception.apps.example"

    assert_receive {:question, ^id, ^expected}
  end

  test "child wildcard proof queries only the apps apex in its bound namespace" do
    {first, one} = replica({127, 0, 0, 1}, fn packet -> reply(packet, @proof) end)
    {second, two} = replica({127, 0, 0, 2}, fn packet -> reply(packet, @proof) end)
    source = put_in(publication(), ["records", Access.at(0), "label"], "")

    assert [%{"label" => "", "proofs" => [@proof]}] =
             Propagation.observe(namespace([first, second]), source, now() + 4000)["records"]

    expected =
      ~c"_acme-challenge.apps.dev-22222222222222222222222222222222.inception.apps.example"

    assert_receive {:question, ^one, ^expected}
    assert_receive {:question, ^two, ^expected}
  end

  defp namespace(peers),
    do: %{
      label: @environment,
      zone: "apps.example",
      public: %{
        "issuer" => "https://ca.example/directory",
        "accept_terms" => true,
        "nameservers" => peers,
        "mailbox" => "hostmaster.example",
        "issuer_ca_pem" => nil,
        "trust_pem" => nil
      }
    }

  defp publication,
    do: %{
      "version" => 1,
      "request_id" => @id,
      "generation" => 1,
      "ttl_ms" => 5000,
      "binding" => %{
        "placement_id" => @id,
        "execution_epoch" => 1,
        "boot_challenge" => String.duplicate("a", 64)
      },
      "porsche_host_key" => nil,
      "audi_host_key" => nil,
      "records" => [%{"label" => @label, "ready" => false, "proofs" => [@proof]}]
    }

  defp replica(ip, respond, count \\ 1) do
    {:ok, listener} = :gen_tcp.listen(0, [:inet, :binary, ip: ip, active: false, packet: 2])
    {:ok, {_, port}} = :inet.sockname(listener)
    id = make_ref()
    owner = self()

    task =
      Task.async(fn ->
        for _ <- 1..count do
          case :gen_tcp.accept(listener, 5000) do
            {:ok, socket} ->
              try do
                {:ok, packet} = :gen_tcp.recv(socket, 0, 2000)
                {:ok, message} = :inet_dns.decode(packet)
                [question] = :inet_dns.msg(message, :qdlist)
                send(owner, {:question, id, :inet_dns.dns_query(question, :domain)})
                if body = respond.(packet), do: :gen_tcp.send(socket, body)
              after
                :gen_tcp.close(socket)
              end

            _ ->
              :ok
          end
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      ref = Process.monitor(task.pid)
      Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        1000 -> flunk("DNS fixture process did not exit")
      end
    end)

    {%{
       "name" => "ns#{elem(ip, 3)}.example",
       "address" => List.to_string(:inet.ntoa(ip)),
       "port" => port
     }, id}
  end

  defp reply(<<id::16, _::16, 1::16, 0::48, question::binary>>, proof, ttl \\ 5),
    do:
      <<id::16, 0x8400::16, 1::16, 1::16, 0::32, question::binary, 0xC00C::16, 16::16, 1::16,
        ttl::32, 44::16, 43, proof::binary>>

  defp now, do: System.monotonic_time(:millisecond)
end
