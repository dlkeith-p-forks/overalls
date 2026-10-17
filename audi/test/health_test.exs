defmodule Audi.HealthTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "gateway health needs both listener observations and positive current authority" do
    check all(before? <- boolean(), after? <- boolean(), authority? <- boolean()) do
      Process.put(:health_calls, 0)

      listeners = fn :gateway ->
        count = Process.get(:health_calls)
        Process.put(:health_calls, count + 1)
        if count == 0, do: before?, else: after?
      end

      control = fn _, :gateway -> if authority?, do: {:ok, %{}}, else: {:error, :unavailable} end

      assert Audi.Health.ready?(%{role: :gateway}, :gateway, [],
               listeners: listeners,
               control: control
             ) ==
               (before? and after? and authority?)
    end
  end

  test "DNS needs a fresh replica as well as authenticated control" do
    directory = Audi.Test.DNSDirectory.start!()

    options = [
      directory: directory,
      listeners: fn :dns -> true end,
      control: fn _, :dns -> {:ok, %{}} end
    ]

    refute Audi.Health.ready?(%{role: :dns}, :dns, [], options)

    :ok =
      Audi.DNS.Directory.publish(directory, 1, %{}, System.monotonic_time(:millisecond) + 5000)

    assert Audi.Health.ready?(%{role: :dns}, :dns, [], options)
    refute Audi.Health.ready?(%{role: :dns}, :gateway, [], options)
    # The view drops an exited writer's snapshot asynchronously.
    Process.exit(Process.whereis(directory), :kill)

    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Audi.DNS.Directory.lookup(directory, "") == :stale,
        do: {:halt, :ok},
        else: {:cont, Process.sleep(10)}
    end)

    refute Audi.Health.ready?(%{role: :dns}, :dns, [], options)
  end

  test "exceptions and missing managed listeners fail closed" do
    refute Audi.Health.ready?(%{role: :gateway}, :gateway)

    refute Audi.Health.ready?(%{role: :gateway}, :gateway, [],
             listeners: fn _ -> true end,
             control: fn _, _ -> raise "private failure" end
           )
  end
end
