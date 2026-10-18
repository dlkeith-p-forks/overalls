defmodule Lilly.VM.BootLogReaderTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.VM.BootLog

  @placement "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    :ok
  end

  test "pending and failed exact launch attempts expose bounded diagnostic bytes", %{
    tmp_dir: directory
  } do
    bytes = :binary.copy(<<0, 255, 13, 10>>, 10_000)

    for state <- [:running, :failed] do
      fixture(directory, state, 2, 2, bytes)
      probe = fn -> flunk("exact launch attempts do not require a VMM or readiness") end
      assert {:ok, first} = BootLog.read(directory, @placement, {1, 2}, 0, probe)
      assert first == %{next: 16_384, bytes: binary_part(bytes, 0, 16_384)}
      assert {:ok, second} = BootLog.read(directory, @placement, {1, 2}, first.next, probe)
      assert second == %{next: 32_768, bytes: binary_part(bytes, 16_384, 16_384)}
    end
  end

  test "new boot metadata cannot relabel a previous log before launch commit", %{
    tmp_dir: directory
  } do
    fixture(directory, :running, 2, 1, "previous physical boot")

    assert {:error, :boot_log_unavailable} =
             BootLog.read(directory, @placement, {1, 2}, 0, fn -> false end)
  end

  test "adopted running generations need a full VMM proof on both sides of the read", %{
    tmp_dir: directory
  } do
    fixture(directory, :running, 2, 1, "same physical boot")

    assert {:ok, %{next: 18, bytes: "same physical boot"}} =
             BootLog.read(directory, @placement, {1, 2}, 0, fn -> true end)

    counter = :counters.new(1, [])

    probe = fn ->
      :counters.add(counter, 1, 1)
      :counters.get(counter, 1) == 1
    end

    assert {:error, :boot_log_unavailable} =
             BootLog.read(directory, @placement, {1, 2}, 0, probe)

    assert :counters.get(counter, 1) == 2
    fixture(directory, :failed, 2, 1, "same physical boot")

    assert {:error, :boot_log_unavailable} =
             BootLog.read(directory, @placement, {1, 2}, 0, fn -> true end)
  end

  test "boot, intent and launch witness substitutions refuse", %{tmp_dir: directory} do
    for {name, contents} <- [
          {"boot.json", "broken"},
          {"intent.bin", <<@placement::binary, 1::64, 1::64, 1>>},
          {"intent.bin", <<@placement::binary, 1::64, 2::64, 0>>},
          {"launch-attempt.bin", <<@other::binary, 1::64, 2::64>>},
          {"launch-attempt.bin", <<@placement::binary, 2::64, 2::64>>},
          {"launch-attempt.bin", <<@placement::binary, 1::64, 3::64>>},
          {"launch-attempt.bin", <<@placement::binary, 1::64, 0::64>>},
          {"launch-attempt.bin", "broken"}
        ] do
      fixture(directory, :running, 2, 2, "current boot")
      write(directory, name, contents)

      assert {:error, :boot_log_unavailable} =
               BootLog.read(directory, @placement, {1, 2}, 0, fn -> true end)
    end

    for name <- ["boot.json", "intent.bin", "launch-attempt.bin", "boot.log"] do
      fixture(directory, :running, 2, 2, "current boot")
      File.rm!(Path.join(directory, name))
      assert {:error, :boot_log_unavailable} = BootLog.read(directory, @placement, {1, 2}, 0)
    end
  end

  test "foreign or stale requests and unsafe log custody refuse", %{tmp_dir: directory} do
    fixture(directory, :running, 2, 2, "private diagnostic")

    for {placement, revision, cursor} <- [
          {@other, {1, 2}, 0},
          {@placement, {2, 2}, 0},
          {@placement, {1, 1}, 0},
          {@placement, {1, 2}, -1},
          {@placement, {1, 2}, 9_223_372_036_854_775_808}
        ] do
      assert {:error, :boot_log_unavailable} =
               BootLog.read(directory, placement, revision, cursor)
    end

    path = Path.join(directory, "boot.log")
    File.chmod!(path, 0o644)
    assert {:error, :boot_log_unavailable} = BootLog.read(directory, @placement, {1, 2}, 0)
    File.chmod!(path, 0o600)
    File.ln!(path, Path.join(directory, "linked"))
    assert {:error, :boot_log_unavailable} = BootLog.read(directory, @placement, {1, 2}, 0)
    File.rm!(Path.join(directory, "linked"))
    File.rename!(path, Path.join(directory, "target"))
    File.ln_s!(Path.join(directory, "target"), path)
    assert {:error, :boot_log_unavailable} = BootLog.read(directory, @placement, {1, 2}, 0)
  end

  test "replacement and boot identity changes during adoption proof discard bytes", %{
    tmp_dir: directory
  } do
    for mutation <- [:inode, :boot, :intent, :attempt] do
      fixture(directory, :running, 2, 1, "old diagnostic")
      counter = :counters.new(1, [])

      probe = fn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 2 do
          case mutation do
            :inode ->
              File.rename!(Path.join(directory, "boot.log"), Path.join(directory, "old.log"))
              write(directory, "boot.log", "new diagnostic")

            :boot ->
              boot = Path.join(directory, "boot.json") |> File.read!() |> JSON.decode!()

              write(
                directory,
                "boot.json",
                JSON.encode!(%{boot | "boot_challenge" => String.duplicate("c", 64)})
              )

            :intent ->
              write(directory, "intent.bin", <<@placement::binary, 1::64, 2::64, 3>>)

            :attempt ->
              write(directory, "launch-attempt.bin", <<@placement::binary, 1::64, 2::64>>)
          end
        end

        true
      end

      assert {:error, :boot_log_unavailable} =
               BootLog.read(directory, @placement, {1, 2}, 0, probe)
    end
  end

  @tag :hegel
  test "pages preserve arbitrary bytes and clamp cursors after truncation", %{
    tmp_dir: directory
  } do
    Hegel.check(
      fn ->
        bytes = draw("bytes", binary(max_length: 40000))
        cursor = draw("cursor", integer(0..50000))
        fixture(directory, :running, 2, 2, bytes)
        start = min(cursor, byte_size(bytes))
        length = min(16_384, byte_size(bytes) - start)
        assert {:ok, page} = BootLog.read(directory, @placement, {1, 2}, cursor)
        assert page == %{next: start + length, bytes: binary_part(bytes, start, length)}
      end,
      test_cases: 100
    )
  end

  @spec fixture(Path.t(), :running | :failed, pos_integer(), pos_integer(), binary()) :: :ok
  defp fixture(directory, state, generation, attempted, bytes) do
    boot = %{
      "version" => 1,
      "placement_id" => @placement,
      "execution_epoch" => 1,
      "generation" => generation,
      "boot_challenge" => String.duplicate("a", 64)
    }

    write(directory, "boot.json", JSON.encode!(boot))
    code = if state == :running, do: 1, else: 3
    write(directory, "intent.bin", <<@placement::binary, 1::64, generation::64, code>>)
    write(directory, "launch-attempt.bin", <<@placement::binary, 1::64, attempted::64>>)
    write(directory, "boot.log", bytes)
  end

  @spec write(Path.t(), String.t(), binary()) :: :ok
  defp write(directory, name, bytes) do
    path = Path.join(directory, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
  end
end
