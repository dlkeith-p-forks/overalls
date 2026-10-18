defmodule OverallsProtocol.SSHLocaleTest do
  use ExUnit.Case, async: true

  test "locale allowlist rejects arbitrary peer values without atom conversion" do
    for locale <- ~w(en hi ja ko ar fil et fi sv pt-BR pt-PT) do
      assert OverallsProtocol.SSHManagement.locale?(locale)
    end

    refute OverallsProtocol.SSHManagement.locale?("not-supported")
    refute OverallsProtocol.SSHManagement.locale?(:en)
    refute OverallsProtocol.SSHManagement.locale?(nil)
  end
end
