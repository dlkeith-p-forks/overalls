defmodule Audi.HTTP.Authority do
  @moduledoc "Independent web lease renewal and expiry for a connection-owning process."
  alias Audi.Authority.StreamGuard
  alias Audi.Control.Client
  require Audi.Events

  # @cc [owner:ghuntley,label:security] audi-web-independent-renewal
  # The connection owner MUST be guarded before opening its guest socket. Renewal
  # MUST run outside both owner and guard, preserving identity and exact binding.
  # A blocked or killed renewal process MUST NOT prevent expiry from killing the
  # owner. Completion stops renewal; neither expiry nor completion can resurrect.
  @spec start(Client.t(), map()) :: {:ok, pid()} | {:error, atom()}
  def start(client, grant) do
    owner = self()
    binding = %{execution: grant.binding, user_id: grant.user_id}

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
          Audi.Authority.HintRenewal.register(vm: grant.binding.vm_id, user: grant.user_id)
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
      {:DOWN, ^ref, :process, ^owner, _} -> close(client, grant)
      {:finished, ^owner} -> close(client, grant)
      # An authority hint for this stream's VM or user renews (or ends) it now.
      {:control_hint, _kind, _id} -> renew_now(owner, ref, guard, client, grant, binding)
    after
      Audi.Authority.HintRenewal.delay(grant.expires_at - now()) ->
        renew_now(owner, ref, guard, client, grant, binding)
    end
  end

  defp renew_now(owner, ref, guard, client, grant, binding) do
    with {:ok, next} <- renewed(renew_grant(client, grant), grant),
         true <- next.binding == grant.binding and next.user_id == grant.user_id,
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
        revoked(grant)
        StreamGuard.revoke(guard)
    end
  end

  defp revoked(%{binding: %{service: :editor} = binding}) do
    Audi.Events.emit("audi.editor_revoked",
      host_id: binding.host_id,
      vm_id: binding.vm_id,
      placement_id: binding.placement_id,
      session_id: binding.session_id,
      guest_account_id: binding.guest_account_id,
      user_id: binding.user_id,
      execution_epoch: binding.execution_epoch,
      generation: binding.generation
    )
  end

  defp revoked(grant) do
    Audi.Events.emit("audi.web_revoked",
      host_id: grant.binding.host_id,
      vm_id: grant.binding.vm_id,
      placement_id: grant.binding.placement_id,
      session_id: grant.binding.session_id,
      execution_epoch: grant.binding.execution_epoch,
      generation: grant.binding.generation
    )
  end

  defp renew_grant(client, %{binding: %{service: :editor}} = grant),
    do: Client.renew_editor(client, grant.ticket, grant)

  defp renew_grant(client, grant), do: Client.renew_web(client, grant.ticket, grant)

  defp close(client, %{binding: %{service: :editor}} = grant) do
    Client.close_editor(client, grant.ticket)
    :ok
  end

  defp close(client, grant) do
    Client.close_web(client, grant.ticket)
    :ok
  end

  defp renewed(result, grant) do
    if Audi.Authority.Renewal.inconclusive?(result) and grant.expires_at > now(),
      do: :retry,
      else: result
  end

  defp now, do: System.monotonic_time(:millisecond)
end
