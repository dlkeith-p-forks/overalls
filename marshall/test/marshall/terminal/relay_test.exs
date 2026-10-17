defmodule Marshall.Terminal.RelayTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Terminal.Relay

  property "completed controls isolate duplicate and stale replies without consuming other messages" do
    check all(
            results <-
              list_of(member_of([{:ok, %{type: :listed}}, {:error, :stream_busy}]),
                min_length: 1,
                max_length: 12
              ),
            duplicates <- integer(0..8)
          ) do
      stream = start_supervised!({Task, fn -> reply_loop([], duplicates) end}, id: make_ref())
      unrelated = make_ref()
      send(self(), {:unrelated, unrelated})

      for result <- results do
        assert Relay.control(stream, %{result: result}) == result
        send(stream, {:replay, self()})
        assert_receive :replayed
        refute_receive {:relay_reply, _, _}, 0
      end

      assert_receive {:unrelated, ^unrelated}
    end
  end

  test "a host reply after the production deadline cannot enter the caller mailbox" do
    owner = self()

    stream =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:relay_control, request} ->
               send(owner, {:request, request})

               receive do
                 :expire ->
                   send(
                     Map.get(request, :reply_to, request.caller),
                     {:relay_reply, request.ref, {:error, :timeout}}
                   )

                   send(owner, :expired)
               end
           end
         end}
      )

    assert Relay.control(stream, %{type: :listing}) == {:error, :stream_timeout}
    assert_receive {:request, %{caller: ^owner}}
    send(stream, :expire)
    assert_receive :expired
    refute_receive {:relay_reply, _, _}, 0
  end

  @spec reply_loop([map()], non_neg_integer()) :: no_return()
  defp reply_loop(previous, duplicates) do
    receive do
      {:relay_control, request} ->
        Enum.each(previous, &deliver/1)
        Enum.each(0..duplicates, fn _ -> deliver(request) end)
        reply_loop([request | previous], duplicates)

      {:replay, owner} ->
        Enum.each(previous, &deliver/1)
        send(owner, :replayed)
        reply_loop(previous, duplicates)
    end
  end

  @spec deliver(map()) :: term()
  defp deliver(request) do
    send(
      Map.get(request, :reply_to, request.caller),
      {:relay_reply, request.ref, request.message.result}
    )
  end
end
