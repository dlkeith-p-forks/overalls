defmodule Porsche.Terminal.Credit do
  @moduledoc """
  Pure input and output accounting for one SSH terminal attachment (ADR-0223).

  Input waits in a bounded queue until the attachment is granted a mode.
  A writable grant releases it as frames of at most 16 KiB, each taking
  `TerminalWindow` credit, and Marshall's cumulative `input_ack` returns that
  credit. A read-only grant discards all input, now and later. Output is
  counted only once delivered locally, so the cumulative `output_ack` never
  runs ahead of what the SSH client received.

  The struct holds counters and queued input only; it is never logged.
  """
  alias OverallsProtocol.TerminalWindow, as: Window

  @chunk 16_384
  @queue_limit 1_048_576

  defstruct mode: :pending,
            window: %Window{},
            queue: <<>>,
            output_frames: 0,
            output_bytes: 0

  @type mode :: :pending | :rw | :ro
  @type t :: %__MODULE__{
          mode: mode(),
          window: Window.t(),
          queue: binary(),
          output_frames: non_neg_integer(),
          output_bytes: non_neg_integer()
        }

  @doc "A fresh account; `read_only: true` discards input from the start."
  @spec new(boolean()) :: t()
  def new(read_only), do: %__MODULE__{mode: if(read_only, do: :ro, else: :pending)}

  @doc "The largest input frame."
  @spec chunk() :: pos_integer()
  def chunk, do: @chunk

  @doc "The most input that may wait for credit or a grant."
  @spec queue_limit() :: pos_integer()
  def queue_limit, do: @queue_limit

  @doc """
  Accepts SSH input. Returns the bytes discarded unread (read-only input),
  which the caller re-opens on the SSH window at once.
  """
  @spec push(t(), binary()) :: {:ok, t(), non_neg_integer()} | {:error, :overflow}
  def push(%__MODULE__{mode: :ro} = credit, bytes), do: {:ok, credit, byte_size(bytes)}

  def push(credit, bytes) do
    if byte_size(credit.queue) + byte_size(bytes) > @queue_limit,
      do: {:error, :overflow},
      else: {:ok, %{credit | queue: credit.queue <> bytes}, 0}
  end

  @doc """
  Applies Marshall's granted mode once. A request for read-only always wins.
  Returns the queued bytes discarded by a read-only result.
  """
  @spec grant(t(), :rw | :ro) :: {t(), non_neg_integer()}
  def grant(%__MODULE__{mode: :pending} = credit, :rw), do: {%{credit | mode: :rw}, 0}

  def grant(%__MODULE__{mode: :pending} = credit, :ro),
    do: {%{credit | mode: :ro, queue: <<>>}, byte_size(credit.queue)}

  # A mode is granted once; later grants change nothing.
  def grant(credit, _granted), do: {credit, 0}

  # @cc [owner:ghuntley,label:capacity;security] porsche-credit-frames
  # take/1 MUST release input only for a writable grant, in order, in frames
  # of at most 16 KiB that each took TerminalWindow credit; it MUST release
  # nothing for pending or read-only attachments.
  @doc "Frames that may be sent now, in order; each already took window credit."
  @spec take(t()) :: {[binary()], t()}
  def take(%__MODULE__{mode: :rw} = credit), do: take(credit, [])
  def take(credit), do: {[], credit}

  defp take(%{queue: <<>>} = credit, frames), do: {Enum.reverse(frames), credit}

  defp take(credit, frames) do
    size = min(byte_size(credit.queue), @chunk)
    <<frame::binary-size(^size), rest::binary>> = credit.queue

    case Window.take(credit.window, size) do
      {:ok, window} -> take(%{credit | window: window, queue: rest}, [frame | frames])
      {:error, :exhausted} -> {Enum.reverse(frames), credit}
    end
  end

  @doc "Applies Marshall's cumulative input receipt."
  @spec acknowledge(t(), term(), term()) :: {:ok, t()} | {:error, :invalid_receipt}
  def acknowledge(credit, frames, bytes) do
    case Window.acknowledge(credit.window, frames, bytes) do
      {:ok, window} -> {:ok, %{credit | window: window}}
      {:error, _} -> {:error, :invalid_receipt}
    end
  end

  @doc "Counts one output frame delivered to the SSH client; returns the cumulative receipt."
  @spec delivered(t(), non_neg_integer()) ::
          {t(), %{frames: pos_integer(), bytes: non_neg_integer()}}
  def delivered(credit, size) when is_integer(size) and size >= 0 do
    credit = %{
      credit
      | output_frames: credit.output_frames + 1,
        output_bytes: credit.output_bytes + size
    }

    {credit, %{frames: credit.output_frames, bytes: credit.output_bytes}}
  end
end
