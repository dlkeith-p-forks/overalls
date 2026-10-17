defmodule Lilly.VM.InceptionExchangeTest do
  use ExUnit.Case, async: true
  alias Lilly.VM.InceptionExchange
  @id "11111111-1111-4111-8111-111111111111"
  @boot %{placement_id: @id, execution_epoch: 1, boot_challenge: String.duplicate("a", 64)}
  @label OverallsProtocol.IngressName.label("dev", @id)

  test "separate framed channel correlates each poll and rejects replay" do
    path = Path.join(System.tmp_dir!(), "inception-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, String.to_charlist(path)},
        active: false,
        packet: :line
      ])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    public = %{
      "issuer" => "https://ca.example/directory",
      "accept_terms" => true,
      "nameservers" => [
        %{"name" => "ns1.example", "address" => "192.0.2.53", "port" => 53},
        %{"name" => "ns2.example", "address" => "198.51.100.53", "port" => 53}
      ],
      "mailbox" => "hostmaster.example",
      "issuer_ca_pem" => nil,
      "trust_pem" => nil
    }

    parent = %{"label" => @label, "zone" => "apps.example", "origin" => "https://parent.example"}

    server =
      Task.async(fn ->
        Enum.reduce(1..2, nil, fn _, previous ->
          {:ok, socket} = :gen_tcp.accept(listener, 2000)
          assert {:ok, "CONNECT 1028\n"} = :gen_tcp.recv(socket, 0, 2000)
          :ok = :gen_tcp.send(socket, "OK 1028\n")
          :ok = :inet.setopts(socket, packet: 4)
          {:ok, bytes} = :gen_tcp.recv(socket, 0, 2000)
          request = JSON.decode!(bytes)

          assert Enum.sort(Map.keys(request)) ==
                   ~w(binding generation observations origins parent public request_id version)

          assert request["public"] == public
          assert request["parent"] == parent
          assert request["origins"]["control"] == "control.#{@label}.inception.apps.example"

          reply =
            Map.take(request, ~w(binding generation request_id version))
            |> Map.merge(%{
              "ttl_ms" => 5000,
              "porsche_host_key" => nil,
              "audi_host_key" => nil,
              "records" => []
            })

          :ok = :gen_tcp.send(socket, JSON.encode!(previous || reply))
          :gen_tcp.close(socket)
          reply
        end)
      end)

    assert {:ok, _} =
             InceptionExchange.poll(
               path,
               @boot,
               @label,
               "apps.example",
               1,
               1000,
               public,
               nil,
               parent
             )

    assert {:error, :inception_exchange_unavailable} =
             InceptionExchange.poll(
               path,
               @boot,
               @label,
               "apps.example",
               1,
               1000,
               public,
               nil,
               parent
             )

    Task.await(server)
  end

  # inception-exchange-single-deadline: every step shares the caller's deadline.
  # The bound adds an explicit scheduler tolerance to the 50ms caller timeout
  # but stays below poll's 5000ms maximum, so a step with its own fixed or
  # infinite timeout still fails this test even on a heavily loaded host.
  @caller_timeout_ms 50
  @scheduler_tolerance_ms 2450
  @maximum_timeout_ms 5000

  test "silent peer cannot extend the total deadline" do
    path =
      Path.join(System.tmp_dir!(), "inception-timeout-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, String.to_charlist(path)}, active: false])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :inception_exchange_unavailable} =
             InceptionExchange.poll(path, @boot, @label, "apps.example", 1, @caller_timeout_ms)

    bound = @caller_timeout_ms + @scheduler_tolerance_ms
    assert bound < @maximum_timeout_ms
    assert System.monotonic_time(:millisecond) - started < bound
  end
end
