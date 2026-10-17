defmodule OverallsProtocol.MachineNameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.{MachineName, SSHCommand}

  property "generated names are valid, deterministic and preserve UUID uniqueness" do
    check all(bytes <- binary(length: 16)) do
      hex = Base.encode16(bytes, case: :lower)

      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary>> =
        hex

      id = Enum.join([a, b, c, d, e], "-")
      name = MachineName.generated(id)
      assert MachineName.valid?(name)
      assert "vm-" <> ^hex = name
      refute MachineName.valid?(id)
      assert {:ok, %{arguments: [^id]}} = SSHCommand.parse("show #{id}")
      assert {:ok, %{arguments: [^name]}} = SSHCommand.parse("show #{name}")
      assert {:error, _} = SSHCommand.parse("new --name #{id}")
    end
  end

  test "image selection accepts the immutable digest used by Marshall" do
    digest = "sha256:" <> String.duplicate("a", 64)
    assert {:ok, %{options: %{"image" => ^digest}}} = SSHCommand.parse("new --image #{digest}")
    assert {:error, _} = SSHCommand.parse("new --image aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    assert {:error, _} = SSHCommand.parse("new --image " <> String.upcase(digest))
  end
end
