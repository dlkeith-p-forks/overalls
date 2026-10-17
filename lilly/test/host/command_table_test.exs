defmodule Lilly.Host.CommandTableTest do
  use ExUnit.Case, async: true

  # A utility added to hostd's closed table must also be accepted by
  # Command, and Command must accept nothing hostd cannot run.
  test "Command accepts exactly the utilities hostd runs" do
    assert Enum.sort(Lilly.Host.Command.names()) == Enum.sort(Lilly.Host.Hostd.utilities())
  end
end
