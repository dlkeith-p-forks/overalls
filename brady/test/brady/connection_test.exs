defmodule Brady.ConnectionTest do
  use ExUnit.Case, async: true

  for scheme <- [:http, :https] do
    test "#{scheme} captures the full socket tuple once before reading guest bytes" do
      scheme = unquote(scheme)
      parent = self()
      reference = make_ref()

      config = %{
        # An admitted loopback fixture, not proof of transparent interception.
        destination_policy: [],
        attribution: fn flow ->
          send(parent, {reference, flow})
          %{attribution: :unresolved}
        end
      }

      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, destination} = :inet.sockname(listener)

      task =
        Task.async(fn ->
          {:ok, accepted} = :gen_tcp.accept(listener)
          Brady.Connection.run(accepted, scheme, config)
        end)

      {:ok, client} =
        :gen_tcp.connect(elem(destination, 0), elem(destination, 1), [:binary, active: false])

      on_exit(fn -> :gen_tcp.close(client) end)
      {:ok, source} = :inet.sockname(client)

      # No HTTP or TLS bytes have been supplied: lookup must precede parsing.
      # The scheduler budget verifies ordering, not a production latency bound.
      assert_receive {^reference, %{source: ^source, destination: ^destination}}, 1_000
      :gen_tcp.close(client)
      assert :ok = Task.await(task)
      refute_receive {^reference, _}
    end
  end
end
