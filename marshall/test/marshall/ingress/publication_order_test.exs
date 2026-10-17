defmodule Marshall.Ingress.PublicationOrderTest do
  use ExUnit.Case, async: false
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress
  alias Marshall.Repo

  # @cc [owner:ghuntley,label:verification] publication-independent-transactions
  # Concurrent revision tests MUST use independently checked-out committed
  # PostgreSQL connections, not shared sandbox transactions. Cleanup MUST target
  # only this test's unique zone and enrolled service IDs. This is transaction
  # ordering evidence, not multi-node or fleet-throughput acceptance.
  test "concurrent DNS identities allocate distinct durable ordered revisions" do
    zone = "test-" <> Ash.UUID.generate() <> ".example"
    previous = Application.get_env(:marshall, :ingress_zone)
    Application.put_env(:marshall, :ingress_zone, zone)

    services =
      unboxed(fn ->
        for n <- 1..2 do
          {token, _} = Ingress.Token.issue()

          {:ok, service} =
            Ingress.configure_service(%{name: zone <> "-#{n}", role: :dns, token: token},
              actor: SystemActor.compute()
            )

          {service.id, token}
        end
      end)

    on_exit(fn ->
      unboxed(fn ->
        for {id, _} <- services do
          uuid = Ecto.UUID.dump!(id)

          Ecto.Adapters.SQL.query!(
            Repo,
            "DELETE FROM ingress_services_versions WHERE version_source_id = $1",
            [uuid],
            log: false
          )

          Ecto.Adapters.SQL.query!(Repo, "DELETE FROM ingress_services WHERE id = $1", [uuid],
            log: false
          )
        end

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM ingress_publications WHERE zone = $1", [zone],
          log: false
        )
      end)

      if previous,
        do: Application.put_env(:marshall, :ingress_zone, previous),
        else: Application.delete_env(:marshall, :ingress_zone)
    end)

    supervisor = start_supervised!({Task.Supervisor, []})

    tasks =
      for n <- 1..8 do
        {_, token} = Enum.at(services, rem(n, 2))

        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            Ingress.dns_snapshot(%{token: token, zone: zone}, actor: SystemActor.compute())
          end)
        end)
      end

    results = Task.await_many(tasks, 15_000)
    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
    revisions = Enum.map(results, fn {:ok, snapshot} -> snapshot.revision end)
    assert Enum.sort(revisions) == Enum.to_list(1..8)

    unboxed(fn ->
      assert [%{revision: 8}] = Ledger.read!(Ingress.Publication, zone: zone)
      {_, token} = hd(services)

      assert {:ok, %{revision: 9}} =
               Ingress.dns_snapshot(%{token: token, zone: zone}, actor: SystemActor.compute())
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
