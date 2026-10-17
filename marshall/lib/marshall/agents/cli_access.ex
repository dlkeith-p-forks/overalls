defmodule Marshall.Agents.CLIAccess do
  @moduledoc "Browser-approved, short-lived access for a dumb user CLI."
  alias Marshall.Agents.{AuditEvent, CLISession, Root}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  @prefix "overalls_agent_"
  @lifetime_seconds 3600

  # @cc [owner:ghuntley,label:security] agent-cli-secret-never-in-browser
  # Browser approval sees only SHA-256(secret), while the CLI sends the full
  # random secret only in the HTTPS Authorization header. Neither credential
  # nor prompt content may enter audit or diagnostic records.

  # @cc [owner:ghuntley,label:security;concurrency] agent-cli-approval-once
  # The unique code_hash index admits exactly one committed session per digest;
  # a concurrent loser MUST receive a clean refusal, never a raised crash. A
  # refused browser approval MUST still commit a content-free cli_refused audit
  # receipt in its own transaction naming the VM, actor and closed reason.
  @spec approve(String.t(), String.t(), Marshall.Accounts.User.t()) ::
          {:ok, CLISession.t()} | {:error, term()}
  def approve(vm_id, code, %Marshall.Accounts.User{} = actor) do
    with true <- OverallsProtocol.uuid?(vm_id),
         true <- valid_code?(code) do
      case Ledger.transaction(fn -> approve!(vm_id, code, actor) end, actor) do
        {:ok, session} ->
          {:ok, session}

        {:error, reason} ->
          record_refusal(vm_id, actor, refusal_reason(reason))
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  def approve(_, _, _), do: {:error, :forbidden}

  defp approve!(vm_id, code, actor) do
    vm = Ledger.lock!(VirtualMachine, vm_id) || Ledger.rollback(:machine_unavailable)
    Marshall.Access.Authorization.require!(vm, actor, "write")

    unless vm.archived_at == nil and vm.desired_state != :deleted and
             match?([%Root{}], Ledger.read!(Root, vm_id: vm.id)),
           do: Ledger.rollback(:machine_unavailable)

    session =
      Ledger.create!(CLISession, :approve, %{
        code_hash: code,
        vm_id: vm.id,
        actor_id: actor.id,
        expires_at: DateTime.add(Ledger.now(), @lifetime_seconds, :second)
      })

    Ledger.create!(AuditEvent, :record, %{
      vm_id: vm.id,
      actor_id: actor.id,
      kind: :cli_approved,
      target_id: session.id,
      outcome: :accepted
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.cli_approved", vm_id: vm.id, actor_id: actor.id)
    end)

    session
  end

  # The refusal receipt commits separately from the failed approval attempt, so
  # a rolled-back unique or authorization check still leaves a durable, closed
  # record of the denied browser action.
  defp record_refusal(vm_id, actor, reason) do
    {:ok, _} =
      Ledger.transaction(
        fn ->
          Ledger.create!(AuditEvent, :record, %{
            vm_id: vm_id,
            actor_id: actor.id,
            kind: :cli_refused,
            outcome: :failed
          })

          Ledger.after_commit(fn ->
            Marshall.Events.emit("agent.cli_refused",
              vm_id: vm_id,
              actor_id: actor.id,
              reason: reason
            )
          end)

          :ok
        end,
        actor
      )

    :ok
  end

  defp refusal_reason(reason) when is_atom(reason), do: reason
  defp refusal_reason(_), do: :already_approved

  @spec session(String.t(), String.t()) ::
          {:ok, :pending | Marshall.Accounts.User.t()} | {:error, atom()}
  def session(vm_id, token) do
    with true <- OverallsProtocol.uuid?(vm_id),
         {:ok, code} <- digest(token) do
      case Ledger.read!(CLISession, code_hash: code, vm_id: vm_id) do
        [] ->
          {:ok, :pending}

        [%CLISession{} = session] ->
          authorize_session(session)
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  @spec authorize(String.t(), String.t()) ::
          {:ok, Marshall.Accounts.User.t()} | {:error, atom()}
  def authorize(vm_id, token) do
    case session(vm_id, token) do
      {:ok, %Marshall.Accounts.User{} = actor} -> {:ok, actor}
      _ -> {:error, :unauthorized}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] agent-cli-expiry-receipt
  # Expiry MUST NOT destroy an approved CLI session silently: each reaped row
  # commits a content-free cli_expired audit receipt and catalogued event in the
  # same transaction that destroys the session.
  @spec reap() :: :ok
  def reap do
    {:ok, _} =
      Ledger.transaction(fn ->
        cutoff = DateTime.add(Ledger.now(), -3600, :second)

        CLISession
        |> Ash.Query.filter(expires_at < ^cutoff)
        |> Ash.Query.sort(expires_at: :asc, id: :asc)
        |> Ash.Query.limit(128)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.each(fn session ->
          Ledger.create!(AuditEvent, :record, %{
            vm_id: session.vm_id,
            actor_id: session.actor_id,
            kind: :cli_expired,
            target_id: session.id,
            outcome: :accepted
          })

          Ash.destroy!(session, action: :expire, actor: SystemActor.compute())

          Ledger.after_commit(fn ->
            Marshall.Events.emit("agent.cli_expired",
              vm_id: session.vm_id,
              session_id: session.id
            )
          end)
        end)
      end)

    :ok
  end

  defp authorize_session(session) do
    vm = List.first(Ledger.read!(VirtualMachine, id: session.vm_id))
    actor = Marshall.Accounts.Security.current(session.actor_id)

    if DateTime.compare(session.expires_at, Ledger.now()) == :gt and
         match?(%Marshall.Accounts.User{deleted_at: nil}, actor) and
         match?(%VirtualMachine{archived_at: nil}, vm) and vm.desired_state != :deleted and
         Marshall.Access.Authorization.allowed?(vm, actor, "write"),
       do: {:ok, actor},
       else: {:error, :unauthorized}
  end

  defp digest(@prefix <> encoded = token) when byte_size(encoded) == 64 do
    with {:ok, bytes} when byte_size(bytes) == 32 <- Base.decode16(encoded, case: :lower),
         true <- Base.encode16(bytes, case: :lower) == encoded do
      {:ok, :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
    else
      _ -> :error
    end
  end

  defp digest(_), do: :error

  defp valid_code?(code) when is_binary(code) and byte_size(code) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, code)

  defp valid_code?(_), do: false
end
