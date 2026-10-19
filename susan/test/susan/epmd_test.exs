defmodule Susan.EpmdTest do
  use ExUnit.Case, async: true

  test "the service node listens on the fixed port and other nodes on an ephemeral one" do
    assert {:ok, 4370} = Susan.Epmd.listen_port_please(:susan, ~c"127.0.0.1")
    assert {:ok, 4370} = Susan.Epmd.listen_port_please(~c"susan", ~c"127.0.0.1")
    assert {:ok, 0} = Susan.Epmd.listen_port_please(:"rpc-1-susan", ~c"127.0.0.1")
    assert {:port, 4370, 6} = Susan.Epmd.port_please(~c"susan", {127, 0, 0, 1})
    assert {:ok, creation} = Susan.Epmd.register_node(:susan, 4370, :inet_tcp)
    assert creation > 3
    assert {:ok, {127, 0, 0, 1}} = Susan.Epmd.address_please(~c"susan", ~c"127.0.0.1", :inet)
  end
end
