defmodule Audi.RosterBootstrapTest do
  use ExUnit.Case, async: true

  test "only exact SSH bootstrap routes select their separate purposes" do
    for {method, origin, purpose} <- [
          {:get, "https://ssh.integration.internal/ssh/v1/roster", :ssh_roster},
          {:post, "https://ssh.integration.internal/ssh/v1/host-certificate",
           :ssh_host_certificate},
          {:get, "https://ssh.integration.internal/ssh/v1/host-certificate", :services},
          {:post, "https://ssh.integration.internal/ssh/v1/host-certificate?extra=1", :services},
          {:post, "https://llm.internal/ssh/v1/host-certificate", :services},
          {:post, "https://ssh.integration.internal/ssh/v1/host-certificate/", :services},
          {:post, "https://ssh.integration.internal/ssh/v1/roster", :services},
          {:get, "https://ssh.integration.internal/ssh/v1/roster?bootstrap=1", :services},
          {:get, "https://llm.internal/ssh/v1/roster", :services},
          {:post, "https://ssh.integration.internal/ssh/v1/authorize", :services},
          {:post, "https://ssh.integration.internal/ssh/v1/login", :services},
          {:get, "https://ssh.integration.internal/ssh/v1/roster/", :services}
        ] do
      conn =
        Plug.Test.conn(method, origin)
        |> Plug.Conn.put_req_header("x-overalls-purpose", "ssh_roster")

      assert Audi.Private.Front.lookup_purpose(conn) == purpose
    end
  end
end
