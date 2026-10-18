defmodule Porsche.SSH.InputTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Porsche.SSH.Input

  property "line normalization is independent of packet boundaries" do
    first = draw("first", string(:alphanumeric, max_length: 100))
    second = draw("second", string(:alphanumeric, max_length: 100))
    suffix = draw("suffix", member_of(["", "é", "猫", "👩‍💻"]))
    size = draw("size", integer(1..30))
    first = first <> suffix
    bytes = first <> "\r\n" <> second <> "\n"

    chunks =
      bytes
      |> :binary.bin_to_list()
      |> Enum.chunk_every(size)
      |> Enum.map(&:erlang.list_to_binary/1)

    state =
      Enum.reduce(chunks, %Input{}, fn chunk, state ->
        {:ok, next, _} = Input.feed(state, chunk)
        next
      end)

    assert {:line, ^first, rest} = Input.take(state)
    assert {:line, ^second, rest} = Input.take(rest)
    assert :empty = Input.take(rest)
  end

  test "backspace, controls, EOF and total pending input have explicit bounds" do
    {:ok, state, _} = Input.feed(%Input{}, "hello\né\bworld\r")
    assert {:line, "hello", state} = Input.take(state)
    assert {:line, "world", _} = Input.take(state)
    assert {:ok, %{escape: "\e"}, []} = Input.feed(%Input{}, <<27>>)
    assert :interrupt = Input.feed(%Input{}, <<3>>)
    assert :close = Input.feed(%Input{}, <<4>>)
    {:ok, state, _} = Input.feed(%Input{}, String.duplicate("x", 8192))
    assert {:error, :command_too_large} = Input.feed(state, "x")
    assert byte_size(Input.finish(state).buffer) == 8192
    assert {:line, _, %{buffer: ""}} = Input.take(Input.finish(state))
  end

  property "fragmented editing and Unicode produce the same submitted command" do
    size = draw("size", integer(1..20))
    word = draw("word", string(:alphanumeric, min_length: 1, max_length: 40))
    bytes = word <> "é👩‍💻猫\e[D\b\eOC!\e[999~\r\n"
    state = feed_chunks(bytes, size)
    assert {:line, command, rest} = Input.take(state)
    assert command == word <> "é猫!"
    assert :empty = Input.take(rest)
    assert state.escape == ""
    assert String.valid?(state.buffer)
  end

  test "history restores the draft and cursor, isolates channels and requires Enter" do
    {:ok, state, _} = Input.feed(%Input{}, "first\nsecond\n")
    {:line, "first", state} = Input.take(state)
    {:line, "second", state} = Input.take(state)
    {:ok, state, []} = Input.feed(state, "draft\e[D\e[A\eOA")
    assert state.buffer == "first"
    assert :empty = Input.take(state)
    {:ok, state, []} = Input.feed(state, "\eOB\e[B")
    assert {state.buffer, state.cursor} == {"draft", 4}
    {:ok, state, ["drafXt"]} = Input.feed(state, "X\r")
    assert {:line, "drafXt", _} = Input.take(state)
    {:ok, fresh, []} = Input.feed(%Input{}, "\e[A")
    assert fresh.buffer == ""
  end

  test "unsupported and partial escapes are bounded and never enter commands" do
    state = feed_chunks("who\e[1;5D\eOPami\e[200~", 1)
    assert state.buffer == "whoami"
    assert :empty = Input.take(state)
    assert {:ok, _, []} = Input.feed(%Input{}, "\e[" <> String.duplicate("1", 62))
    assert {:error, :invalid_input} = Input.feed(%Input{}, "\e[" <> String.duplicate("1", 63))
    assert {:error, :invalid_input} = Input.feed(%Input{}, <<255>>)
    assert {:error, :invalid_input} = Input.feed(%Input{}, "\u009b")
    assert {:line, "whoami", _} = Input.take(Input.finish(state))
    state = feed_chunks("whoami\n\e[A", 1)
    {:line, "whoami", state} = Input.take(state)
    assert :empty = Input.take(Input.finish(state))
    state = feed_chunks("ok\e[", 1) |> Input.finish()
    assert {:line, "ok", _} = Input.take(state)
    state = feed_chunks("ok" <> <<0xF0, 0x9F>>, 1) |> Input.finish()
    assert {:line, "ok", _} = Input.take(state)
  end

  test "edits cannot cross submitted lines and history obeys both limits" do
    state = feed_chunks("one\n\b\e[Dtwo\n", 1)
    assert {:line, "one", state} = Input.take(state)
    assert {:line, "two", _} = Input.take(state)

    state =
      Enum.reduce(1..120, %Input{}, fn n, state ->
        {:ok, state, _} = Input.feed(state, "command-#{n}\n")
        {:line, _, state} = Input.take(state)
        state
      end)

    assert length(state.history) == 100
    assert List.last(state.history) == "command-21"
    # Seed valid submitted entries to exercise byte eviction independently of typing cost.
    state = %{state | history: List.duplicate(String.duplicate("x", 8191), 8)}
    {:ok, state, _} = Input.feed(state, "another-command\n")
    assert Enum.sum(Enum.map(state.history, &byte_size/1)) <= 65536
    assert length(state.history) == 8
    {:ok, state, _} = Input.feed(%Input{}, String.duplicate("x", 8191) <> "\n")
    assert {:error, :command_too_large} = Input.feed(state, "y")
    assert {:error, :command_too_large} = Input.feed(state, "\e[A")
  end

  test "insertion that joins the following combining mark keeps a grapheme boundary" do
    {:ok, state, _} = Input.feed(%Input{}, "́\e[De")
    assert {state.buffer, state.cursor} == {"é", 1}
    {:ok, state, _} = Input.feed(state, "\b")
    assert {state.buffer, state.cursor} == {"", 0}
  end

  property "arbitrary packet bytes cannot grow parser state beyond its bounds" do
    chunks = draw("chunks", list_of(binary(max_length: 100), max_length: 20))

    Enum.reduce_while(chunks, %Input{}, fn bytes, state ->
      case Input.feed(state, bytes) do
        {:ok, next, _} ->
          assert Input.pending_bytes(next) <= 8192
          assert byte_size(next.escape) <= 64
          assert byte_size(next.utf8) <= 3
          assert length(next.history) <= 100
          assert Enum.sum(Enum.map(next.history, &byte_size/1)) <= 65536
          assert String.valid?(next.buffer)
          assert next.cursor <= String.length(next.buffer)
          {:cont, next}

        _ ->
          {:halt, state}
      end
    end)
  end

  defp feed_chunks(bytes, size) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.reduce(%Input{}, fn chunk, state ->
      {:ok, state, _} = Input.feed(state, :erlang.list_to_binary(chunk))
      state
    end)
  end
end
