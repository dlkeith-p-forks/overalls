defmodule OverallsProtocol.SSHHostCertificateFixtureTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.SSHHostCertificate

  # Issued by this module and verified by Mila's Dart port of the same format.
  @vectors Path.expand("fixtures/ssh_host_certificates.json", __DIR__)
  @external_resource @vectors

  test "shared host certificates verify exactly where Mila verifies them" do
    %{"version" => 1, "certificates" => rows} = @vectors |> File.read!() |> JSON.decode!()
    assert Enum.any?(rows, & &1["valid"])
    assert Enum.any?(rows, &(not &1["valid"]))

    for row <- rows do
      result =
        SSHHostCertificate.verify(row["line"], row["ca"], row["leaf"], row["principal"], row["now"])

      assert match?({:ok, _}, result) == row["valid"], inspect(Map.delete(row, "line"))
    end
  end
end
