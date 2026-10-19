defmodule Susan.Poke.Machine do
  @moduledoc """
  The pure poke pipeline (ADR-0224):

      validate -> authenticate -> replay -> rate -> claim -> send (one retry) -> respond

  The machine decides control flow only. It emits one command at a time and
  consumes the effect's outcome as the next event; `Susan.Poke` interprets the
  commands. Payloads never enter machine state, so the state can be logged,
  inspected and property-tested without carrying request data.
  """

  @enforce_keys [:step, :attempt, :checks]
  defstruct [:step, :attempt, :checks]

  @type step ::
          :validate | :authenticate | :replay | :rate | :claim | :send | :done
  @type check :: :valid | :authenticated | :fresh | :admitted | :claimed
  @type t :: %__MODULE__{step: step(), attempt: 0..2, checks: [check()]}
  @type body :: :rejected | :unregistered | :rate_limited | :unavailable | :empty
  @type response :: {:respond, 204 | 400 | 404 | 410 | 429 | 503, body(), pos_integer() | nil}
  @type command ::
          :validate
          | :authenticate
          | :check_replay
          | :check_rate
          | :claim
          | {:send, 1 | 2}
          | response()
  @type refusal ::
          :unknown_key
          | :expired_key
          | :deployment_mismatch
          | :bad_signature
          | :install_blocked
          | :denylisted
          | :unregistered
  @type event ::
          :valid
          | :invalid
          | :authenticated
          | {:refused, refusal() | :stale | :replayed}
          | :fresh
          | :duplicate
          | :in_flight
          | :admitted
          | {:limited, atom(), pos_integer()}
          | :claimed
          | :sent
          | :unregistered
          | {:retry, pos_integer()}
          | :rejected
          | :unavailable

  @spec start() :: {t(), command()}
  def start, do: {%__MODULE__{step: :validate, attempt: 0, checks: []}, :validate}

  # @cc [owner:ghuntley,label:security;reliability] susan-poke-pipeline-order
  # A provider send MUST be commanded only after validation, authentication,
  # replay, rate admission and delivery claim have all succeeded, in that
  # order; there MUST be at most two sends per request; every path MUST end in
  # exactly one response; 204 MUST follow only a provider send or an already
  # delivered receipt; any unexpected event MUST end in 503 without a send.
  @spec next(t(), event()) :: {t(), command()}
  def next(%__MODULE__{step: :validate} = s, :valid),
    do: advance(s, :authenticate, :valid, :authenticate)

  def next(%__MODULE__{step: :validate} = s, :invalid), do: respond(s, 400, :rejected)

  def next(%__MODULE__{step: :authenticate} = s, :authenticated),
    do: advance(s, :replay, :authenticated, :check_replay)

  def next(%__MODULE__{step: :authenticate} = s, {:refused, :unregistered}),
    do: respond(s, 410, :unregistered)

  def next(%__MODULE__{step: :authenticate} = s, {:refused, reason})
      when reason in [
             :unknown_key,
             :expired_key,
             :deployment_mismatch,
             :bad_signature,
             :install_blocked,
             :denylisted
           ],
      do: respond(s, 404, :rejected)

  def next(%__MODULE__{step: :replay} = s, :fresh), do: advance(s, :rate, :fresh, :check_rate)
  def next(%__MODULE__{step: :replay} = s, :duplicate), do: respond(s, 204, :empty)
  def next(%__MODULE__{step: :replay} = s, :in_flight), do: respond(s, 429, :rate_limited, 5)

  def next(%__MODULE__{step: :replay} = s, {:refused, :unregistered}),
    do: respond(s, 410, :unregistered)

  def next(%__MODULE__{step: :replay} = s, {:refused, reason}) when reason in [:stale, :replayed],
    do: respond(s, 400, :rejected)

  def next(%__MODULE__{step: :rate} = s, :admitted), do: advance(s, :claim, :admitted, :claim)

  def next(%__MODULE__{step: :rate} = s, {:limited, _scope, retry})
      when is_integer(retry) and retry > 0,
      do: respond(s, 429, :rate_limited, retry)

  def next(%__MODULE__{step: :claim} = s, :claimed),
    do: {%{s | step: :send, attempt: 1, checks: [:claimed | s.checks]}, {:send, 1}}

  def next(%__MODULE__{step: :claim} = s, :in_flight), do: respond(s, 429, :rate_limited, 5)
  def next(%__MODULE__{step: :claim} = s, :duplicate), do: respond(s, 204, :empty)

  def next(%__MODULE__{step: :send} = s, :sent), do: respond(s, 204, :empty)
  def next(%__MODULE__{step: :send} = s, :unregistered), do: respond(s, 410, :unregistered)
  def next(%__MODULE__{step: :send} = s, :rejected), do: respond(s, 400, :rejected)
  def next(%__MODULE__{step: :send} = s, :unavailable), do: respond(s, 503, :unavailable, 60)

  def next(%__MODULE__{step: :send, attempt: 1} = s, {:retry, retry})
      when is_integer(retry) and retry > 0,
      do: {%{s | attempt: 2}, {:send, 2}}

  def next(%__MODULE__{step: :send, attempt: 2} = s, {:retry, retry})
      when is_integer(retry) and retry > 0,
      do: respond(s, 503, :unavailable, retry)

  def next(%__MODULE__{step: :done} = s, _event), do: {s, {:respond, 503, :unavailable, 60}}
  def next(%__MODULE__{} = s, _unexpected), do: respond(s, 503, :unavailable, 60)

  @doc "Whether the machine has reached its single response."
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{step: step}), do: step == :done

  defp advance(s, step, check, command),
    do: {%{s | step: step, checks: [check | s.checks]}, command}

  defp respond(s, status, body, retry \\ nil),
    do: {%{s | step: :done}, {:respond, status, body, retry}}
end
