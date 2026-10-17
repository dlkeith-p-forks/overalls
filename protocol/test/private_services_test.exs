defmodule OverallsProtocol.PrivateServicesTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.PrivateServices
  @host "01234567-89ab-4def-8123-456789abcdef"

  test "canonical endpoint, zone and approved lifetime policy" do
    assert PrivateServices.hostname() == "llm.internal"
    assert PrivateServices.address() == "169.254.254.1"
    assert PrivateServices.integration_zone() == "integration.internal"
    assert PrivateServices.lifetimes() == %{root: 20, intermediate: 10, server: 10}

    assert PrivateServices.certificate_names() == [
             "llm.internal",
             "*.integration.internal"
           ]
  end

  property "execution epochs cannot be missing, negative or unbounded" do
    check all(
            epoch <-
              one_of([
                integer(-100_000..0),
                constant(9_223_372_036_854_775_808)
              ])
          ) do
      assert {:error, :invalid_binding} = PrivateServices.binding(wire_binding(epoch))
    end
  end

  property "extra peer fields never become authority" do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 32)) do
      assert {:error, :invalid_binding} =
               PrivateServices.binding(Map.put(wire_binding(1), "untrusted_" <> suffix, @host))
    end
  end

  test "closed valid binding retains execution identity" do
    assert {:ok, %{host_id: @host, vm_id: @host, placement_id: @host, execution_epoch: 7}} =
             PrivateServices.binding(wire_binding(7))
  end

  defp wire_binding(epoch),
    do: %{
      "host_id" => @host,
      "vm_id" => @host,
      "placement_id" => @host,
      "execution_epoch" => epoch
    }
end
