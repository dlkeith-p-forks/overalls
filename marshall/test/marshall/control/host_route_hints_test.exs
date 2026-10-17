defmodule Marshall.Control.HostRouteHintsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute.HostReports

  test "a host session transition hints its gateway catalog and the DNS zone" do
    %{host: host} = host_fixture()
    parent = self()
    handler = "host-route-hint-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:marshall, :control, :hint],
      fn _, _, %{kind: kind, id: id}, _ -> send(parent, {:hint, kind, id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    host_id = host.id
    assert {:ok, epoch} = HostReports.connect(host_id)

    for kind <- [:host, :gateway_catalog, :dns_snapshot],
        do: assert_receive({:hint, ^kind, ^host_id}, 1_000)

    assert {:ok, :ok} = HostReports.disconnect(host_id, epoch)

    for kind <- [:host, :gateway_catalog, :dns_snapshot],
        do: assert_receive({:hint, ^kind, ^host_id}, 1_000)
  end
end
