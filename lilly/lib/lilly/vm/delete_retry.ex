defmodule Lilly.VM.DeleteRetry do
  @moduledoc "Bound repeated physical delete attempts while retaining the durable fence."

  # @cc [owner:ghuntley,label:recovery] delete-retry-preserves-fence
  # Delay only another attempt for the same failed delete generation; it MUST
  # never mark deletion complete or postpone a newly accepted command.
  @spec delay(pos_integer()) :: pos_integer()
  def delay(attempt) when is_integer(attempt) and attempt > 0 do
    min(30_000, 1000 * Bitwise.bsl(1, min(attempt - 1, 5)))
  end
end
