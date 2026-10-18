defmodule Marshall.Ingress.PropagationTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Ingress.ACME.Propagation

  @owner "apps.example.test"
  @ip {127, 0, 0, 1}

  # @cc [owner:ghuntley,label:verification;protocol] classified-acme-propagation
  # Generated live TCP replies MUST distinguish authoritative proof readiness,
  # absent proof, malformed DNS, expired TTL, value mismatch and transport loss.
  # Only exact, live proof bytes from the configured peer may acknowledge readiness.
  property "DNS proof checks retain the negative cause class", test_cases: 100 do
    proof_bytes = draw("proof_bytes", binary(length: 32))
    mode = draw("mode", member_of([:valid, :absent, :malformed, :expired, :mismatch, :transport]))
    proof = Base.url_encode64(proof_bytes, padding: false)
    {listener, port, server} = start_server(mode, proof)

    try do
      expected =
        case mode do
          :valid -> :ok
          :absent -> {:error, :absent}
          :malformed -> {:error, :malformed_reply}
          :expired -> {:error, :ttl_out_of_window}
          :mismatch -> {:error, :value_mismatch}
          :transport -> {:error, :transport}
        end

      assert Propagation.check(@owner, [proof], [{@ip, port}]) == expected
      server_pid = server.pid
      assert_receive {:dns_query, ^server_pid}, 2_000
      assert :ok = Task.await(server, 2_000)
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
    end
  end

  property "each configured DNS replica must return the exact live proof", test_cases: 100 do
    proof_bytes = draw("proof_bytes", binary(length: 32))
    mode = draw("mode", member_of([:valid, :absent, :malformed, :expired, :mismatch, :transport]))
    failed_first? = draw("failed_first?", boolean())
    proof = Base.url_encode64(proof_bytes, padding: false)
    first = start_server(:valid, proof)
    second = start_server(mode, proof)
    peers = if failed_first?, do: [second, first], else: [first, second]

    try do
      expected =
        case mode do
          :valid -> :ok
          :absent -> {:error, :absent}
          :malformed -> {:error, :malformed_reply}
          :expired -> {:error, :ttl_out_of_window}
          :mismatch -> {:error, :value_mismatch}
          :transport -> {:error, :transport}
        end

      assert Propagation.check(@owner, [proof], Enum.map(peers, &{@ip, elem(&1, 1)})) ==
               expected

      if expected == :ok do
        first_pid = elem(first, 2).pid
        second_pid = elem(second, 2).pid
        assert_receive {:dns_query, ^first_pid}, 2_000
        assert_receive {:dns_query, ^second_pid}, 2_000
      end
    after
      for {listener, _port, task} <- [first, second] do
        :gen_tcp.close(listener)
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "invalid owner and peer configuration is classified without a DNS dial" do
    proof = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert Propagation.check("Bad.Owner", [proof], [{@ip, 53}]) == {:error, :invalid_request}
    assert Propagation.check(@owner, [proof], []) == {:error, :invalid_request}

    assert Propagation.check(@owner, [proof], [{@ip, 53}, {@ip, 53}]) ==
             {:error, :invalid_request}
  end

  @spec start_server(atom(), binary()) :: {:gen_tcp.socket(), :inet.port_number(), Task.t()}
  defp start_server(mode, proof) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: 2, ip: @ip])
    {:ok, {@ip, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        case :gen_tcp.accept(listener, 5_000) do
          {:ok, socket} ->
            try do
              {:ok, query} = :gen_tcp.recv(socket, 0, 2_000)
              send(parent, {:dns_query, self()})
              response = reply(mode, query, proof)
              if is_binary(response), do: :ok = :gen_tcp.send(socket, response)
              :ok
            after
              :gen_tcp.close(socket)
            end

          {:error, :closed} ->
            :ok
        end
      end)

    {listener, port, server}
  end

  @spec reply(atom(), binary(), binary()) :: binary() | :close
  defp reply(:transport, _query, _proof), do: :close

  defp reply(mode, <<id::16, _::binary>> = query, proof) do
    question = binary_part(query, 12, byte_size(query) - 12)

    case mode do
      :absent ->
        <<id::16, 0x8400::16, 1::16, 0::16, 0::32, question::binary>>

      :malformed ->
        <<id::16, 0x8400::16, 1::16, 1::16, 0::32, question::binary, 0>>

      _ ->
        ttl = if mode == :expired, do: 0, else: 5

        value =
          if mode == :mismatch do
            {:ok, <<first, rest::binary>>} = Base.url_decode64(proof, padding: false)
            Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
          else
            proof
          end

        answer = <<0xC00C::16, 16::16, 1::16, ttl::32, 44::16, 43, value::binary>>
        <<id::16, 0x8400::16, 1::16, 1::16, 0::32, question::binary, answer::binary>>
    end
  end
end
