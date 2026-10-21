defmodule PeachReflectionContractTest do
  use Covenant.Case, component: "peach.reflection"
  import Plug.Test
  alias Peach.Fixtures

  @tag obligation: "peach.reflection.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Peach.Application,
      Peach.Config,
      Peach.Control,
      Peach.Control.Link,
      Peach.Credential,
      Peach.Events,
      Peach.HTTP,
      Peach.Privacy
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "peach.reflection.I2"
  test "unknown paths, methods and queries never reach Marshall" do
    config = Fixtures.config(Peach.ControlStub.start(fn _, _ -> flunk("control called") end))

    assert call(config, :get, "/secrets").status == 404
    assert call(config, :post, "/guest").status == 405
    assert call(config, :get, "/guest?x=1").status == 403
    refute_received {:control_request, _}
  end

  @tag obligation: "peach.reflection.I3"
  test "foreign and malformed bindings are refused" do
    config = Fixtures.config(Peach.ControlStub.start(fn _, _ -> flunk("control called") end))
    foreign = Fixtures.binding(%{"host_id" => Fixtures.other_host()})

    assert call(config, :get, "/", Fixtures.encode(foreign)).status == 403
    assert call(config, :get, "/", "not-base64!").status == 403
    assert call(config, :get, "/", nil).status == 403
    refute_received {:control_request, _}
  end

  @tag obligation: "peach.reflection.I4"
  test "control refusal and invalid snapshots return no projection" do
    refused = Fixtures.config(Peach.ControlStub.start(fn _, _ -> {:error, "invalid_request"} end))
    assert call(refused, :get, "/").status == 403

    invalid = Fixtures.config(Peach.ControlStub.start(fn _, _ -> {:ok, %{"version" => 2}} end))
    conn = call(invalid, :get, "/")
    assert conn.status == 503
    refute conn.resp_body =~ "guest"
  end

  defp call(config, method, path, binding \\ :default) do
    binding = if binding == :default, do: Fixtures.encode(Fixtures.binding()), else: binding
    conn = conn(method, path)

    conn =
      if binding, do: Plug.Conn.put_req_header(conn, "x-overalls-binding", binding), else: conn

    Peach.HTTP.call(conn, Peach.HTTP.init(config))
  end
end
