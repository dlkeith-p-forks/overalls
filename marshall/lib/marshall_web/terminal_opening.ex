defmodule MarshallWeb.TerminalOpening do
  @moduledoc "Automatic workspace opening state; durable idempotency belongs to Terminal.Authority."

  @type phase :: :waiting | :opening | :ready | :closed | :failed
  @type execution :: String.t()
  @type t :: %{execution: execution() | nil, phase: phase(), rejections: non_neg_integer()}

  # A guest account that is not yet reconciled (roster sync lag after boot or a
  # grant change) is refused as :rejected; that is usually transient, so it
  # retries this many times before the failure becomes definitive.
  @rejection_budget 5

  @spec new() :: t()
  def new, do: %{execution: nil, phase: :waiting, rejections: 0}

  defguard is_retryable(reason)
           when reason in [
                  :terminal_open_pending,
                  :terminal_unavailable,
                  :stream_unavailable,
                  :stream_timeout,
                  :stream_busy,
                  :stream_not_ready,
                  :timeout
                ]

  @spec for_execution(t(), execution()) :: t()
  def for_execution(%{execution: execution} = state, execution), do: state

  def for_execution(_state, execution),
    do: %{execution: execution, phase: :waiting, rejections: 0}

  # @cc [owner:ghuntley,label:recovery] transient-terminal-opening-preserves-intent
  # Retryable failures MUST preserve the opening phase and execution identity.
  # :rejected (guest account not yet reconciled) is retryable for a bounded
  # number of attempts per execution, then definitive. A definitive opening
  # failure MUST prevent automatic retries for that execution.
  @spec failed(t(), atom()) :: t()
  def failed(state, reason) when is_retryable(reason), do: state

  def failed(%{rejections: count} = state, :rejected) when count + 1 < @rejection_budget,
    do: %{state | rejections: count + 1}

  def failed(state, _reason), do: finish(state, :failed)

  @doc "Whether a failure left automatic opening pending (it will retry)."
  @spec pending?(t()) :: boolean()
  def pending?(%{phase: phase}), do: phase in [:waiting, :opening]

  # @cc [owner:ghuntley,label:recovery] automatic-terminal-no-resurrection
  # Only a running writable execution with a successful empty listing may
  # request automatic opening. Once ready, closed or failed, empty listings
  # MUST NOT request another shell in that execution. A new execution resets it.
  @spec observe(t(), execution(), boolean(), boolean(), boolean()) :: {t(), :open | :none}
  def observe(state, execution, running?, writable?, has_sessions?) do
    state = for_execution(state, execution)

    cond do
      has_sessions? -> {finish(state, :ready), :none}
      state.phase == :ready -> {finish(state, :closed), :none}
      not running? or not writable? -> {state, :none}
      state.phase in [:waiting, :opening] -> {finish(state, :opening), :open}
      true -> {state, :none}
    end
  end

  @spec finish(t(), phase()) :: t()
  def finish(state, phase), do: %{state | phase: phase}
end
