defmodule Audi.Inception.Authority do
  @moduledoc "Independent nested lease renewal and expiry for a connection-owning process."
  alias Audi.Authority.StreamGuard
  alias Audi.Control.Client
  require Audi.Events

  # @cc [owner:ghuntley,label:security] audi-nested-independent-renewal
  # The connection owner MUST be guarded before opening its guest socket. Renewal
  # MUST run outside both owner and guard, preserving identity and exact binding.
  # A blocked or killed renewal process MUST NOT prevent expiry from killing the
  # owner. Completion stops renewal; neither expiry nor completion can resurrect.
  @spec start(Client.t(), map()) :: {:ok, pid()} | {:error, atom()}
  def start(client, grant) do
    owner = self()
    binding = %{execution: grant.binding, host_key: grant.host_key}

    with {:ok, guard} <-
           StreamGuard.start_link(
             owner: owner,
             binding: binding,
             requested_at: grant.requested_at,
             ttl: grant.expires_at - grant.requested_at
           ) do
      worker =
        spawn(fn ->
          :logger.update_process_metadata(%{audi_private: true})

          Audi.Authority.HintRenewal.register(
            vm: Map.get(grant.binding, :vm_id),
            user: Map.get(grant, :user_id)
          )

          ref = Process.monitor(owner)
          renew(owner, ref, guard, client, grant, binding)
        end)

      {:ok, worker}
    end
  end

  @spec finish(pid()) :: :ok
  def finish(worker) do
    send(worker, {:finished, self()})
    :ok
  end

  defp renew(owner, ref, guard, client, grant, binding) do
    receive do
      {:DOWN, ^ref, :process, ^owner, _} -> close(client, grant.ticket)
      {:finished, ^owner} -> close(client, grant.ticket)
      # An authority hint for this stream's VM or user renews (or ends) it now.
      {:control_hint, _kind, _id} -> renew_now(owner, ref, guard, client, grant, binding)
    after
      Audi.Authority.HintRenewal.delay(grant.expires_at - now()) ->
        renew_now(owner, ref, guard, client, grant, binding)
    end
  end

  defp renew_now(owner, ref, guard, client, grant, binding) do
    with {:ok, next} <- renewed(Client.renew_nested(client, grant.ticket, grant), grant),
         true <- next.binding == grant.binding and next.host_key == grant.host_key,
         :ok <-
           StreamGuard.renew(
             guard,
             binding,
             next.requested_at,
             next.expires_at - next.requested_at
           ) do
      renew(owner, ref, guard, client, Map.put(next, :ticket, grant.ticket), binding)
    else
      # Inconclusive: keep the current lease and retry; the guard still
      # ends the stream at the deadline if renewal never recovers.
      :retry ->
        renew(owner, ref, guard, client, grant, binding)

      _ ->
        Audi.Events.emit("audi.nested_revoked",
          host_id: grant.binding.host_id,
          vm_id: grant.binding.vm_id,
          placement_id: grant.binding.placement_id,
          session_id: grant.binding.session_id,
          execution_epoch: grant.binding.execution_epoch,
          generation: grant.binding.generation
        )

        StreamGuard.revoke(guard)
    end
  end

  defp close(client, ticket) do
    Client.close_nested(client, ticket)
    :ok
  end

  defp renewed(result, grant) do
    if Audi.Authority.Renewal.inconclusive?(result) and grant.expires_at > now(),
      do: :retry,
      else: result
  end

  defp now, do: System.monotonic_time(:millisecond)
end
