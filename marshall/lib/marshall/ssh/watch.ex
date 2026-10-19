defmodule Marshall.SSH.Watch do
  @moduledoc """
  Authorizes a Porsche `watch` subscription (ADR-0222).

  The answer names the canonical machine and thread identifiers the session's
  account may currently read. Porsche routes control hints only for those
  identifiers; a hint is never authority, so a watcher re-reads through the
  ordinary authorized commands. Porsche repeats this check on every heartbeat,
  so revocation ends a watch within one heartbeat interval.
  """
  use Ash.Resource.Actions.Implementation
  alias Marshall.Compute.Ledger
  alias Marshall.SSH.Authority
  require Marshall.Events

  @type result :: %{session_id: String.t(), machines: [String.t()], threads: [String.t()]}

  @refusals [:unauthorized, :approval_required, :forbidden, :not_found, :invalid_request]

  # @cc [owner:ghuntley,label:security;observability] ssh-watch-subscription-authority
  # A watch subscription MUST authenticate the gateway and session like a read
  # command, resolve every machine through current read authority and every
  # thread through current thread read authority, and refuse the whole
  # subscription if any name is not readable. Refusals emit only a closed reason.
  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) :: {:ok, result()} | {:error, term()}
  def run(input, _options, _context) do
    args = input.arguments

    Ledger.transaction(fn ->
      Authority.with_actor!(
        args.gateway_token,
        args.session_token,
        fn actor, session ->
          %{
            session_id: session.id,
            machines: Enum.map(args.machines, &machine!(&1, actor)),
            threads: Enum.map(args.threads, &thread!(&1, actor))
          }
        end,
        false
      )
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        refused = if reason in @refusals, do: reason, else: :unavailable
        Marshall.Events.emit("ssh.watch_subscription_refused", reason: refused)
        Marshall.SSH.Error.result({:error, reason})
    end
  end

  @spec machine!(String.t(), Marshall.Accounts.User.t()) :: String.t()
  defp machine!(reference, actor) do
    case Marshall.Compute.resolve_vm(%{reference: reference}, actor: actor) do
      {:ok, vm} -> vm.id
      {:error, reason} -> Ledger.rollback(refusal(reason))
    end
  end

  @spec thread!(String.t(), Marshall.Accounts.User.t()) :: String.t()
  defp thread!(id, actor) do
    case Marshall.Threads.get_thread(%{thread_id: id}, actor: actor) do
      {:ok, thread} -> thread.id
      {:error, reason} -> Ledger.rollback(refusal(reason))
    end
  end

  @spec refusal(term()) :: :forbidden | :not_found
  defp refusal(reason) do
    case Marshall.Threads.error_reason(reason) do
      :not_found -> :not_found
      _ -> :forbidden
    end
  end
end
