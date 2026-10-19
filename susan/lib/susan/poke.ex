defmodule Susan.Poke do
  @moduledoc """
  Interprets `Susan.Poke.Machine` commands against the real effects: the
  keyring, Ed25519 verification, the replay window, delivery receipts, rate
  buckets, install identities, the audit trail and the provider senders.

  Unauthenticated requests (a key that does not open or a signature that does
  not verify) cause no database write; both checks always run, so their
  timing does not reveal which one failed, and both answer 404 with the same
  body as a malformed request.
  """
  require Ash.Query
  require Susan.Events

  alias Susan.Audit.Log
  alias Susan.Poke.{Machine, Request}
  alias Susan.{PushKey, Provider, RateLimiter, Replay}
  alias Susan.Relay.{DeliveryReceipt, InstallIdentity, KeyDenial, UnregisteredToken}

  @stale_claim_seconds 60

  @type input :: %{
          body: binary(),
          install_key: String.t() | nil,
          signature: String.t() | nil,
          source: binary(),
          now: integer()
        }
  @type context :: %{
          input: input(),
          config: Susan.Config.t(),
          request: Request.t() | nil,
          key: PushKey.t() | nil,
          fingerprint: String.t() | nil,
          identity: InstallIdentity.t() | nil,
          receipt: DeliveryReceipt.t() | nil
        }

  @spec handle(input(), Susan.Config.t()) :: Machine.response()
  def handle(input, config) do
    context = %{
      input: input,
      config: config,
      request: nil,
      key: nil,
      fingerprint: nil,
      identity: nil,
      receipt: nil
    }

    {machine, command} = Machine.start()
    run(machine, command, context)
  end

  defp run(_machine, {:respond, _, _, _} = response, _context), do: response

  defp run(machine, command, context) do
    {event, context} =
      try do
        effect(command, context)
      rescue
        _ -> {:unavailable, context}
      end

    {machine, next} = Machine.next(machine, event)
    run(machine, next, context)
  end

  defp effect(:validate, %{input: input} = context) do
    case Request.parse(input.body, input.install_key, input.signature) do
      {:ok, request} -> {:valid, %{context | request: request}}
      :error -> refuse(:malformed, :invalid, context)
    end
  end

  defp effect(:authenticate, %{request: request, config: config, input: input} = context) do
    # Both checks always run so their timing does not reveal which failed.
    opened = PushKey.open(config.keyring, request.push_key, input.now)
    signed = Request.signed?(request)

    case {opened, signed} do
      {_, false} ->
        refuse(:bad_signature, {:refused, :bad_signature}, context)

      {{:error, reason}, true} ->
        refuse(reason, {:refused, reason}, context)

      {{:ok, key}, true} ->
        fingerprint = Request.fingerprint(request.install_key)
        authorize(%{context | key: key, fingerprint: fingerprint})
    end
  end

  defp effect(
         :check_replay,
         %{request: request, fingerprint: fingerprint, input: input} = context
       ) do
    case Replay.claim(fingerprint, request.nonce, request.issued_at, input.now) do
      {:error, reason} ->
        audited_refusal(reason, {:refused, reason}, context)

      :ok ->
        receipt = DeliveryReceipt.find!(fingerprint, request.delivery_id)
        context = %{context | receipt: receipt}

        case receipt do
          nil ->
            {:fresh, context}

          %{status: :sent} ->
            duplicate(context)

          %{status: :unregistered} ->
            refuse(:unregistered, {:refused, :unregistered}, context)

          %{status: :failed} ->
            {:fresh, context}

          %{status: :sending} = r ->
            if stale_claim?(r, input.now), do: {:fresh, context}, else: in_flight(context)
        end
    end
  end

  defp effect(:check_rate, %{key: key, fingerprint: fingerprint, input: input} = context) do
    buckets = [
      {:key, key.key_id},
      {:install, fingerprint},
      {:source, input.source},
      {:global, :all}
    ]

    case RateLimiter.check(buckets, context.config.limits) do
      :ok ->
        context = admit_identity(context)
        _ = Log.append(:poke_accepted, :ok, correlation(context))
        Susan.Events.emit("susan.poke_accepted", provider: key.provider, duplicate: :no)
        {:admitted, context}

      {:limited, scope, retry, first} ->
        Susan.Events.emit("susan.rate_limited", scope: scope, retry_after: retry)

        if first do
          _ = Log.append(:rate_limited, :refused, Map.put(correlation(context), :reason, scope))
          if scope == :install, do: limit_identity(context)
        end

        {{:limited, scope, retry}, context}
    end
  end

  defp effect(:claim, %{receipt: nil, fingerprint: fingerprint, request: request} = context) do
    case DeliveryReceipt.claim(fingerprint, request.delivery_id) do
      {:ok, receipt} -> {:claimed, %{context | receipt: receipt}}
      {:error, _} -> in_flight(context)
    end
  end

  defp effect(:claim, %{receipt: %DeliveryReceipt{} = receipt, input: input} = context) do
    stale = DateTime.add(DateTime.from_unix!(input.now), -@stale_claim_seconds, :second)

    result =
      DeliveryReceipt
      |> Ash.Query.filter(
        id == ^receipt.id and
          (status == :failed or (status == :sending and updated_at < ^stale))
      )
      |> Ash.bulk_update(:reclaim, %{}, return_records?: true, strategy: :atomic)

    case result do
      %Ash.BulkResult{status: :success, records: [reclaimed]} ->
        {:claimed, %{context | receipt: reclaimed}}

      _ ->
        in_flight(context)
    end
  end

  defp effect({:send, attempt}, %{key: key, request: request, config: config} = context) do
    if attempt == 2, do: Process.sleep(250)

    message = %Provider{
      push_key: key,
      ciphertext: request.ciphertext,
      collapse_id: request.collapse_id,
      kind: request.kind,
      issued_at: request.issued_at
    }

    outcome = Provider.deliver(message, config)

    Susan.Events.emit("susan.provider_outcome",
      provider: key.provider,
      outcome: outcome_label(outcome),
      attempt: attempt
    )

    case {outcome, attempt} do
      {:sent, _} ->
        finish(context, :sent, :provider_sent, :ok, nil)
        {:sent, context}

      {:unregistered, _} ->
        _ = UnregisteredToken.record(token_digest(config, key), key.provider)
        finish(context, :unregistered, :provider_unregistered, :refused, nil)
        {:unregistered, context}

      {{:retry, retry}, 1} ->
        {{:retry, retry}, context}

      {{:retry, retry}, 2} ->
        finish(context, :failed, :provider_failed, :failed, :retry)
        {{:retry, retry}, context}

      {other, _} when other in [:rejected, :unavailable] ->
        finish(context, :failed, :provider_failed, :failed, other)
        {other, context}
    end
  end

  defp authorize(%{key: key, request: request, config: config} = context) do
    cond do
      key.deployment != request.deployment ->
        audited_refusal(:deployment_mismatch, {:refused, :deployment_mismatch}, context)

      KeyDenial.denied!(key.key_id) != nil ->
        audited_refusal(:denylisted, {:refused, :denylisted}, context)

      true ->
        identity = identity(context.fingerprint)
        context = %{context | identity: identity}

        cond do
          identity.state == :blocked ->
            audited_refusal(:install_blocked, {:refused, :install_blocked}, context)

          UnregisteredToken.lookup!(token_digest(config, key)) != nil ->
            audited_refusal(:unregistered, {:refused, :unregistered}, context)

          true ->
            {:authenticated, context}
        end
    end
  end

  defp identity(fingerprint) do
    case InstallIdentity.by_fingerprint!(fingerprint) do
      nil ->
        case InstallIdentity.first_seen(fingerprint) do
          {:ok, identity} ->
            _ = Log.append(:install_first_seen, :ok, %{install_fingerprint: fingerprint})
            Susan.Events.emit("susan.install_transition", to: :unknown)
            identity

          {:error, _} ->
            InstallIdentity.by_fingerprint!(fingerprint) || raise "install identity unavailable"
        end

      identity ->
        identity
    end
  end

  defp admit_identity(%{identity: %{state: :unknown} = identity} = context),
    do: transition(context, &InstallIdentity.trust/1, identity, :trusted)

  defp admit_identity(%{identity: %{state: :rate_limited} = identity} = context),
    do: transition(context, &InstallIdentity.recover/1, identity, :trusted)

  defp admit_identity(context), do: context

  defp limit_identity(%{identity: %{state: state} = identity} = context)
       when state in [:unknown, :trusted],
       do: transition(context, &InstallIdentity.rate_limit/1, identity, :rate_limited)

  defp limit_identity(context), do: context

  defp transition(context, fun, identity, to) do
    case fun.(identity) do
      {:ok, updated} ->
        Susan.Events.emit("susan.install_transition", to: to)
        %{context | identity: updated}

      {:error, _} ->
        context
    end
  end

  defp finish(%{receipt: receipt} = context, status, action, outcome, reason) do
    _ = DeliveryReceipt.finish(receipt, status)
    fields = correlation(context)

    _ =
      Log.append(action, outcome, if(reason, do: Map.put(fields, :reason, reason), else: fields))

    :ok
  end

  defp duplicate(%{key: key} = context) do
    Susan.Events.emit("susan.poke_accepted", provider: key.provider, duplicate: :yes)
    {:duplicate, context}
  end

  defp in_flight(context) do
    Susan.Events.emit("susan.poke_rejected", reason: :in_flight)
    {:in_flight, context}
  end

  defp refuse(reason, event, context) do
    Susan.Events.emit("susan.poke_rejected", reason: reason)
    {event, context}
  end

  defp audited_refusal(reason, event, context) do
    _ = Log.append(:poke_rejected, :refused, Map.put(correlation(context), :reason, reason))
    refuse(reason, event, context)
  end

  defp correlation(%{key: key, fingerprint: fingerprint, request: request}) do
    %{
      install_fingerprint: fingerprint,
      key_id: key && key.key_id,
      provider: key && key.provider,
      delivery_id: request && request.delivery_id
    }
  end

  defp stale_claim?(%{updated_at: updated_at}, now),
    do: now - DateTime.to_unix(updated_at) > @stale_claim_seconds

  defp outcome_label(:sent), do: :sent
  defp outcome_label(:unregistered), do: :unregistered
  defp outcome_label({:retry, _}), do: :retry
  defp outcome_label(:rejected), do: :rejected
  defp outcome_label(:unavailable), do: :unavailable

  @doc "Keyed digest of a provider token for the negative cache; never the token itself."
  @spec token_digest(Susan.Config.t(), PushKey.t()) :: String.t()
  def token_digest(config, %PushKey{provider: provider, token: token}) do
    :crypto.mac(:hmac, :sha256, Susan.Keyring.derive(config.keyring, "token-digest"), [
      Atom.to_string(provider),
      0,
      token
    ])
    |> Base.encode16(case: :lower)
  end
end
