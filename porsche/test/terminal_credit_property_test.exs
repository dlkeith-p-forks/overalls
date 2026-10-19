defmodule Porsche.Terminal.CreditPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.TerminalWindow, as: Window
  alias Porsche.Terminal.Credit

  @type op :: {:input, non_neg_integer()} | {:ack, non_neg_integer()} | {:grant, :rw | :ro}

  # @cc [owner:ghuntley,label:verification;capacity;security] porsche-credit-model
  # Against a reference model: released input is always an in-order prefix
  # of writable input, in non-empty frames of at most 16 KiB, outstanding
  # credit never exceeds TerminalWindow's 16 frames or 256 KiB, a read-only
  # attachment (requested or granted) never releases a frame, and every byte
  # not released is either queued or reported as discarded for the SSH window.
  property "input release respects the window, ordering and read-only refusal" do
    read_only = draw("read_only", boolean())

    ops =
      draw(
        "ops",
        list(
          one_of([
            map(integer(0..40_000), &{:input, &1}),
            map(integer(0..20), &{:ack, &1}),
            map(member_of([:rw, :ro]), &{:grant, &1})
          ]),
          max_length: 40
        )
      )

    model = %{
      credit: Credit.new(read_only),
      typed: <<>>,
      accepted: <<>>,
      sent: [],
      acked: 0,
      discarded: 0,
      ro_ever: read_only,
      counter: 0
    }

    final = Enum.reduce(ops, model, &step/2)
    sent = IO.iodata_to_binary(final.sent)

    assert byte_size(sent) + byte_size(final.credit.queue) + final.discarded ==
             byte_size(final.typed)

    # Released frames plus the queue are exactly the accepted input, in order.
    assert sent <> final.credit.queue == final.accepted
    if final.ro_ever, do: assert(sent == <<>>)
  end

  @spec step(op(), map()) :: map()
  defp step({:input, size}, model) do
    bytes = :binary.copy(<<rem(model.counter, 251)>>, size)
    model = %{model | counter: model.counter + 1}

    case Credit.push(model.credit, bytes) do
      {:ok, credit, discarded} ->
        if credit.mode == :ro, do: assert(discarded == size), else: assert(discarded == 0)

        release(%{
          model
          | credit: credit,
            typed: model.typed <> bytes,
            accepted: if(discarded == 0, do: model.accepted <> bytes, else: model.accepted),
            discarded: model.discarded + discarded
        })

      {:error, :overflow} ->
        assert byte_size(model.credit.queue) + size > Credit.queue_limit()
        model
    end
  end

  defp step({:grant, mode}, model) do
    before = model.credit.mode
    {credit, discarded} = Credit.grant(model.credit, mode)

    case before do
      :pending ->
        assert credit.mode == mode
        if mode == :ro, do: assert(discarded == byte_size(model.credit.queue))

      _ ->
        assert credit.mode == before and discarded == 0
    end

    release(%{
      model
      | credit: credit,
        accepted: binary_part(model.accepted, 0, byte_size(model.accepted) - discarded),
        discarded: model.discarded + discarded,
        ro_ever: model.ro_ever or credit.mode == :ro
    })
  end

  defp step({:ack, count}, model) do
    window = model.credit.window
    outstanding = window.sent_frames - window.acknowledged_frames

    if count > outstanding do
      # A receipt for frames never sent is refused and changes nothing.
      future = window.sent_frames + 1
      assert {:error, :invalid_receipt} = Credit.acknowledge(model.credit, future, 0)
      model
    else
      frames = window.acknowledged_frames + count
      bytes = window.acknowledged_bytes + (window.pending |> Enum.take(count) |> Enum.sum())
      {:ok, credit} = Credit.acknowledge(model.credit, frames, bytes)
      release(%{model | credit: credit, acked: frames})
    end
  end

  defp release(model) do
    {frames, credit} = Credit.take(model.credit)

    if credit.mode != :rw, do: assert(frames == [])

    for frame <- frames,
        do: assert(byte_size(frame) in 1..Credit.chunk())

    window = credit.window
    assert window.sent_frames - window.acknowledged_frames <= Window.frame_limit()
    assert window.sent_bytes - window.acknowledged_bytes <= Window.byte_limit()

    # Only an exhausted window may leave writable input queued.
    if credit.mode == :rw and credit.queue != <<>>,
      do: assert({:error, :exhausted} = Window.take(window, min(byte_size(credit.queue), 16_384)))

    %{model | credit: credit, sent: [model.sent | frames]}
  end

  property "output receipts count exactly the frames and bytes delivered" do
    sizes = draw("sizes", list(integer(0..65_535), max_length: 50))

    {credit, receipts} =
      Enum.reduce(sizes, {Credit.new(false), []}, fn size, {credit, receipts} ->
        {credit, receipt} = Credit.delivered(credit, size)
        {credit, [receipt | receipts]}
      end)

    receipts = Enum.reverse(receipts)

    for {receipt, index} <- Enum.with_index(receipts, 1) do
      assert receipt.frames == index
      assert receipt.bytes == sizes |> Enum.take(index) |> Enum.sum()
    end

    assert credit.output_frames == length(sizes)
  end
end
