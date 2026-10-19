defmodule Marshall.Notifications.DeliveryWorker do
  @moduledoc """
  Sends one Delivery to Susan with bounded, jittered retries (ADR-0225).

  Each attempt commits `sending` before any network I/O, sends outside every
  database transaction, then records the classified outcome under the row
  lock. The delivery id is Susan's idempotency key, so a resend after a lost
  response or a crashed attempt cannot notify twice.
  """
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 8,
    unique: [
      period: :infinity,
      keys: [:delivery_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications
  alias Marshall.Notifications.{Delivery, Device, InstallIdentities, Retry, Susan}
  alias OverallsProtocol.{PushPoke, SusanPoke}
  require Marshall.Events

  @type attempt :: %{
          delivery: Delivery.t(),
          device: Device.t(),
          attempt: pos_integer()
        }

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()} | {:error, atom()}
  def perform(%Oban.Job{args: %{"delivery_id" => id}, attempt: attempt, max_attempts: maximum}) do
    case begin(id) do
      {:send, prepared} ->
        outcome = send_poke(prepared)
        finish(prepared, outcome, attempt >= maximum)

      :done ->
        :ok
    end
  end

  @impl Oban.Worker
  @spec backoff(Oban.Job.t()) :: pos_integer()
  def backoff(%Oban.Job{attempt: attempt}), do: Retry.backoff(attempt, :rand.uniform())

  @impl Oban.Worker
  @spec timeout(Oban.Job.t()) :: pos_integer()
  def timeout(_job), do: 60_000

  # @cc [owner:ghuntley,label:recovery;concurrency] notification-send-outside-transaction
  # A delivery MUST be committed as sending, with its attempt counted, before
  # the request leaves Marshall, and the outcome MUST be applied only to the
  # same attempt under the row lock. Expired, inactive, disabled or
  # preference-off deliveries MUST drop without contacting Susan.
  @spec begin(String.t()) :: {:send, attempt()} | :done
  defp begin(id) do
    result =
      Ledger.transaction(fn ->
        delivery = Ledger.lock!(Delivery, id)
        now = Ledger.now()

        cond do
          is_nil(delivery) or delivery.state in Delivery.terminal_states() ->
            {:done, nil}

          DateTime.compare(now, delivery.expires_at) != :lt ->
            {:done, drop!(delivery, :expired, now)}

          true ->
            device = Ledger.lock!(Device, delivery.device_id)

            cond do
              is_nil(device) or device.state != :active ->
                {:done, drop!(delivery, :device_inactive, now)}

              not device.enabled or not Notifications.enabled?() ->
                {:done, drop!(delivery, :preference_off, now)}

              true ->
                # A row left in sending by a lost attempt resends identically.
                delivery =
                  if delivery.state == :sending,
                    do: Ledger.update!(delivery, :retry_later, %{failure_reason: :transport}),
                    else: delivery

                delivery =
                  Ledger.update!(delivery, :begin_send, %{
                    attempts: delivery.attempts + 1,
                    sending_started_at: now
                  })

                {:send, %{delivery: delivery, device: device, attempt: delivery.attempts}}
            end
        end
      end)

    case result do
      {:ok, {:send, prepared}} ->
        transition(prepared.delivery, :begin_send)
        {:send, prepared}

      {:ok, {:done, nil}} ->
        :done

      {:ok, {:done, delivery}} ->
        transition(delivery, delivery.drop_reason)
        :done

      {:error, _} ->
        :done
    end
  end

  @spec send_poke(attempt()) :: Susan.outcome() | {:unsealable, atom()}
  defp send_poke(%{delivery: delivery, device: device}) do
    host = deployment_host()

    with {:ok, %{seed: seed}} <- InstallIdentities.signer(),
         %Device{push_key: push_key} <-
           Ash.load!(device, [:push_key], actor: SystemActor.compute()),
         {:ok, ciphertext} <-
           PushPoke.seal(
             %{kind: delivery.kind, route: delivery.route},
             device.enc_public_key,
             host
           ),
         {:ok, body} <-
           SusanPoke.encode(%{
             ciphertext: ciphertext,
             collapse_id: collapse_id(seed, delivery.collapse_key),
             delivery_id: delivery.id,
             deployment: host,
             issued_at: System.os_time(:second),
             kind: delivery.kind,
             nonce: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
             push_key: push_key
           }) do
      Susan.poke(body, SusanPoke.sign(body, seed))
    else
      {:error, :request_too_large} -> {:unsealable, :request_too_large}
      _ -> {:unsealable, :unsealable}
    end
  end

  @spec finish(attempt(), Susan.outcome() | {:unsealable, atom()}, boolean()) ::
          :ok | {:snooze, pos_integer()} | {:error, atom()}
  defp finish(%{delivery: %{id: id}, attempt: attempt}, outcome, final?) do
    result =
      Ledger.transaction(fn ->
        delivery = Ledger.lock!(Delivery, id)
        now = Ledger.now()

        if is_nil(delivery) or delivery.state != :sending or delivery.attempts != attempt do
          # Another attempt (or the reconciler) already owns this row.
          {:stale, nil}
        else
          apply_outcome(delivery, outcome, final?, now)
        end
      end)

    case result do
      {:ok, {decision, delivery}} ->
        report(delivery, outcome)
        decision(decision)

      {:error, _} ->
        {:error, :temporarily_unavailable}
    end
  end

  @spec apply_outcome(Delivery.t(), term(), boolean(), DateTime.t()) :: {term(), Delivery.t()}
  defp apply_outcome(delivery, outcome, final?, now) do
    case Retry.decide(outcome, final?) do
      :delivered ->
        {:ok,
         Ledger.update!(delivery, :deliver, %{last_status: status(outcome), finished_at: now})}

      :invalidate ->
        if device = Ledger.lock!(Device, delivery.device_id) do
          if device.state in [:pending, :active] do
            Ledger.update!(device, :invalidate, %{finished_at: now})

            Ledger.after_commit(fn ->
              Marshall.Events.emit("notifications.device_transition",
                device_id: device.id,
                state: :invalidated,
                reason: :provider_unregistered
              )
            end)
          end
        end

        {:ok,
         Ledger.update!(delivery, :drop, %{
           drop_reason: :device_inactive,
           last_status: status(outcome),
           finished_at: now
         })}

      {:permanent, reason} ->
        {:ok,
         Ledger.update!(delivery, :fail_permanent, %{
           failure_reason: reason,
           last_status: status(outcome),
           finished_at: now
         })}

      {:retry, reason, delay} ->
        next = DateTime.add(now, delay || 0, :second)

        if DateTime.compare(next, delivery.expires_at) != :lt do
          {:ok, drop!(delivery, :expired, now, status(outcome))}
        else
          delivery =
            Ledger.update!(delivery, :retry_later, %{
              failure_reason: reason,
              last_status: status(outcome),
              next_attempt_at: next
            })

          {if(delay, do: {:snooze, max(delay, 1)}, else: {:error, reason}), delivery}
        end
    end
  end

  @spec decision(term()) :: :ok | {:snooze, pos_integer()} | {:error, atom()}
  defp decision(:ok), do: :ok
  defp decision(:stale), do: :ok
  defp decision({:snooze, seconds}), do: {:snooze, seconds}
  defp decision({:error, reason}), do: {:error, reason}

  @spec drop!(Delivery.t(), Delivery.drop_reason(), DateTime.t(), non_neg_integer() | nil) ::
          Delivery.t()
  defp drop!(delivery, reason, now, last_status \\ nil),
    do:
      Ledger.update!(delivery, :drop, %{
        drop_reason: reason,
        last_status: last_status,
        finished_at: now
      })

  @spec report(Delivery.t() | nil, term()) :: :ok
  defp report(nil, _outcome), do: :ok

  defp report(delivery, outcome) do
    case outcome do
      {:retry, reason, status, _} ->
        Marshall.Events.emit("notifications.susan_unavailable", reason: reason, status: status)

      {:rejected, status} ->
        Marshall.Events.emit("notifications.poke_refused", reason: :rejected, status: status)

      {:unsealable, reason} ->
        Marshall.Events.emit("notifications.poke_refused", reason: reason)

      _ ->
        :ok
    end

    reason =
      case delivery.state do
        :delivered -> :sent
        :dropped -> delivery.drop_reason
        _ -> delivery.failure_reason
      end

    transition(delivery, reason)
  end

  @spec transition(Delivery.t(), atom() | nil) :: :ok
  defp transition(delivery, reason) do
    Marshall.Events.emit("notifications.delivery_transition",
      delivery_id: delivery.id,
      device_id: delivery.device_id,
      state: delivery.state,
      reason: reason || :sent
    )
  end

  @spec status(term()) :: non_neg_integer() | nil
  defp status({_, status}) when is_integer(status), do: status
  defp status({:retry, _, status, _}), do: status
  defp status(_), do: nil

  @doc "The deployment host bound into the poke AAD and Susan push key."
  @spec deployment_host() :: String.t()
  def deployment_host, do: URI.parse(MarshallWeb.Endpoint.url()).host

  @doc "An opaque per-install collapse id: Susan never learns thread identifiers."
  @spec collapse_id(<<_::256>>, String.t()) :: String.t()
  def collapse_id(seed, collapse_key) do
    key = PushPoke.hkdf(seed, "", "overalls-susan-collapse-v1", 32)

    :crypto.mac(:hmac, :sha256, key, collapse_key)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
