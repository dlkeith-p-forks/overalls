defmodule OverallsProtocol.TerminalWindow do
  @moduledoc "Byte and frame credit accounting with cumulative, replay-safe consumption receipts."
  @bytes 262_144
  @frames 16
  @maximum 9_223_372_036_854_775_807
  defstruct sent_bytes: 0,
            sent_frames: 0,
            acknowledged_bytes: 0,
            acknowledged_frames: 0,
            pending: []

  @type t :: %__MODULE__{
          sent_bytes: non_neg_integer(),
          sent_frames: non_neg_integer(),
          acknowledged_bytes: non_neg_integer(),
          acknowledged_frames: non_neg_integer(),
          pending: [non_neg_integer()]
        }
  @type failure :: {:error, :exhausted | :invalid_receipt}

  @spec new() :: t()
  def new, do: %__MODULE__{}
  @spec byte_limit() :: pos_integer()
  def byte_limit, do: @bytes
  @spec frame_limit() :: pos_integer()
  def frame_limit, do: @frames

  # @cc [owner:ghuntley,label:capacity;protocol] terminal-window-two-dimensional-bound
  # Each accepted frame MUST consume both byte and frame credit. Outstanding
  # data MUST never exceed 256 KiB or sixteen frames, including empty frames.
  # The window contains lengths/counters only, never terminal data.
  @spec take(t(), non_neg_integer()) :: {:ok, t()} | {:error, :exhausted}
  def take(window, bytes) when is_integer(bytes) and bytes in 0..65_535 do
    if window.sent_frames - window.acknowledged_frames < @frames and
         window.sent_bytes - window.acknowledged_bytes + bytes <= @bytes and
         window.sent_bytes + bytes <= @maximum and window.sent_frames < @maximum do
      {:ok,
       %{
         window
         | sent_bytes: window.sent_bytes + bytes,
           sent_frames: window.sent_frames + 1,
           pending: window.pending ++ [bytes]
       }}
    else
      {:error, :exhausted}
    end
  end

  def take(_, _), do: {:error, :exhausted}

  # @cc [owner:ghuntley,label:protocol;recovery] terminal-credit-receipts-are-cumulative
  # Consumption receipts MUST match an exact prefix of sent frames. Duplicate
  # or older receipts MUST grant no additional credit. Future or inconsistent
  # receipts MUST fail without changing the window.
  @spec acknowledge(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_receipt}
  def acknowledge(window, frames, bytes)
      when is_integer(frames) and frames >= 0 and is_integer(bytes) and bytes >= 0 do
    cond do
      frames <= window.acknowledged_frames and bytes <= window.acknowledged_bytes ->
        {:ok, window}

      frames <= window.acknowledged_frames or frames > window.sent_frames ->
        {:error, :invalid_receipt}

      true ->
        {consumed, pending} = Enum.split(window.pending, frames - window.acknowledged_frames)

        if window.acknowledged_bytes + Enum.sum(consumed) == bytes do
          {:ok,
           %{window | pending: pending, acknowledged_frames: frames, acknowledged_bytes: bytes}}
        else
          {:error, :invalid_receipt}
        end
    end
  end

  def acknowledge(_, _, _), do: {:error, :invalid_receipt}
end
