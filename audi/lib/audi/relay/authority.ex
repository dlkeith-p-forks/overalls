defmodule Audi.Relay.Authority do
  @moduledoc "Independent renewal of both gateway identities and the destination stream."
  alias Audi.Authority.StreamGuard
  alias Audi.Control.Client

  @spec start(Client.t(), map(), String.t(), map()) :: {:ok, pid()} | {:error, atom()}
  def start(client, preface, peer, grant) do
    owner = self()

    with {:ok, guard} <-
           StreamGuard.start_link(
             owner: owner,
             binding: %{execution: grant.binding, user_id: grant.user_id},
             requested_at: grant.requested_at,
             ttl: grant.expires_at - grant.requested_at
           ) do
      worker =
        spawn(fn ->
          :logger.update_process_metadata(%{audi_private: true})
          renew(Process.monitor(owner), guard, client, preface, peer, grant)
        end)

      {:ok, worker}
    end
  end

  @spec renew(reference(), pid(), Client.t(), map(), String.t(), map()) :: :ok
  defp renew(owner_ref, guard, client, preface, peer, grant) do
    receive do
      {:DOWN, ^owner_ref, :process, _, _} -> :ok
    after
      Audi.Authority.HintRenewal.delay(grant.expires_at - System.monotonic_time(:millisecond)) ->
        case Client.relay_exchange(client, :renew, preface, peer) do
          {:ok, next} ->
            if next.binding == grant.binding and next.user_id == grant.user_id and
                 StreamGuard.renew(
                   guard,
                   %{execution: next.binding, user_id: next.user_id},
                   next.requested_at,
                   next.expires_at - next.requested_at
                 ) == :ok,
               do: renew(owner_ref, guard, client, preface, peer, next),
               else: StreamGuard.revoke(guard)

          failure ->
            if Audi.Authority.Renewal.inconclusive?(failure) and
                 grant.expires_at > System.monotonic_time(:millisecond),
               do: renew(owner_ref, guard, client, preface, peer, grant),
               else: StreamGuard.revoke(guard)
        end
    end
  end
end
