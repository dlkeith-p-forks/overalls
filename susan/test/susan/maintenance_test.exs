defmodule Susan.MaintenanceTest do
  use Susan.DataCase, async: false

  alias Susan.Repo
  alias Susan.Relay.{DeliveryReceipt, UnregisteredToken}

  test "the daily job prunes receipts, digests and audit rows by retention" do
    {:ok, old} = DeliveryReceipt.claim(String.duplicate("c", 64), Susan.PushKey.uuid())
    {:ok, _fresh} = DeliveryReceipt.claim(String.duplicate("c", 64), Susan.PushKey.uuid())
    {:ok, _} = UnregisteredToken.record(String.duplicate("d", 64), :fcm)

    Repo.query!(
      "UPDATE delivery_receipts SET inserted_at = inserted_at - interval '2 days' WHERE id = $1",
      [Ecto.UUID.dump!(old.id)]
    )

    Repo.query!(
      "UPDATE unregistered_tokens SET recorded_at = recorded_at - interval '31 days'",
      []
    )

    assert :ok = perform_job(Susan.Maintenance.Prune, %{})
    assert [_] = Ash.read!(DeliveryReceipt)
    assert [] = Ash.read!(UnregisteredToken)
    assert [%{action: :prune, count: 0}] = Susan.Audit.Log.read()
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
