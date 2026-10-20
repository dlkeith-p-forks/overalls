defmodule Marshall.Agents.AttachmentState do
  @moduledoc "Closed attachment lifecycle transition table."
  # @cc [owner:ghuntley,label:durability] attachment-state-closed-transitions
  # Attachment lifecycle changes MUST use this closed transition table; deleted is terminal.

  @type state ::
          :pending | :uploading | :available | :quarantined | :failed | :deleting | :deleted

  @spec transition(state(), state()) :: :ok | {:error, :invalid_transition}
  def transition(from, to) do
    if to in Map.get(transitions(), from, []), do: :ok, else: {:error, :invalid_transition}
  end

  @spec transitions() :: %{state() => [state()]}
  def transitions do
    %{
      pending: [:uploading, :failed],
      uploading: [:available, :quarantined, :failed],
      available: [:quarantined, :deleting],
      quarantined: [:deleting],
      failed: [:uploading, :deleting],
      deleting: [:deleted, :deleting],
      deleted: []
    }
  end
end
