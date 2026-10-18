defmodule OverallsAntithesis.SDKTest do
  use ExUnit.Case, async: false

  alias OverallsAntithesis.SDK
  alias OverallsAntithesis.SDK.Details
  require SDK

  def observe(condition) do
    {
      SDK.reachable("Overalls Antithesis SDK startup path executed"),
      SDK.always("Overalls SDK records both observed outcomes", condition, %Details{
        observed_count: 1
      })
    }
  end

  setup_all do
    helper =
      Path.join(System.tmp_dir!(), "overalls-sdk-writer-#{System.unique_integer([:positive])}")

    source = Path.expand("../native/sdk_writer.c", __DIR__)

    {output, status} =
      System.cmd(
        "cc",
        [
          "-std=c11",
          "-O2",
          "-Wall",
          "-Wextra",
          "-Werror",
          "-DSDK_WRITER_TEST_FAULTS",
          "-o",
          helper,
          source
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    on_exit(fn -> File.rm(helper) end)
    %{helper: helper}
  end

  setup %{helper: helper} do
    dir =
      Path.join(System.tmp_dir!(), "overalls-sdk-output-#{System.unique_integer([:positive])}")

    state_dir = dir <> "-state"
    File.mkdir!(dir)
    File.mkdir!(state_dir)
    Application.stop(:overalls_antithesis_sdk)
    :persistent_term.erase({OverallsAntithesis.SDK.Writer, :admission})
    System.put_env("ANTITHESIS_OUTPUT_DIR", dir)
    System.put_env("OVERALLS_ANTITHESIS_WRITER", helper)
    System.put_env("OVERALLS_ANTITHESIS_STATE_DIR", state_dir)
    System.delete_env("OVERALLS_ANTITHESIS_TEST_SHORT_WRITE")
    System.delete_env("OVERALLS_ANTITHESIS_TEST_DELAY_REPLY")

    on_exit(fn ->
      Application.stop(:overalls_antithesis_sdk)
      :persistent_term.erase({OverallsAntithesis.SDK.Writer, :admission})
      System.delete_env("ANTITHESIS_OUTPUT_DIR")
      System.delete_env("OVERALLS_ANTITHESIS_WRITER")
      System.delete_env("OVERALLS_ANTITHESIS_STATE_DIR")
      System.delete_env("OVERALLS_ANTITHESIS_TEST_SHORT_WRITE")
      System.delete_env("OVERALLS_ANTITHESIS_TEST_DELAY_REPLY")
      File.rm_rf(dir)
      File.rm_rf(state_dir)
    end)

    %{dir: dir, state_dir: state_dir}
  end

  test "declarations and evaluations use matching identities, legal kinds, and a single line each",
       %{dir: dir} do
    start_sdk()
    assert :written = SDK.declare_catalog([__MODULE__])
    assert :written = SDK.setup_complete()
    assert :duplicate = SDK.setup_complete()
    assert :written = elem(observe(true), 0)
    assert :duplicate = elem(observe(true), 0)
    assert :written = elem(observe(false), 1)

    lines = File.read!(Path.join(dir, "sdk.jsonl")) |> String.split("\n", trim: true)
    assert length(lines) == 6
    records = Enum.map(lines, &Jason.decode!/1)
    assert Enum.all?(lines, &String.starts_with?(&1, "{"))
    assert Enum.count(records, &Map.has_key?(&1, "antithesis_setup")) == 1

    assertions =
      Enum.filter(records, &Map.has_key?(&1, "antithesis_assert"))
      |> Enum.map(& &1["antithesis_assert"])

    assert Enum.count(assertions, &(&1["hit"] == false)) == 2
    assert Enum.count(assertions, &(&1["hit"] == true)) == 3
    assert Enum.all?(assertions, &(&1["id"] == &1["message"] and is_binary(&1["id"])))

    assert Enum.all?(
             assertions,
             &(is_integer(&1["location"]["begin_line"]) and &1["location"]["begin_line"] > 0)
           )

    assert Enum.all?(
             Enum.filter(assertions, &(&1["hit"] == false)),
             &(&1["condition"] == false and not Map.has_key?(&1, "details"))
           )

    assert Enum.any?(assertions, &(&1["hit"] and &1["condition"] == false))
  end

  test "invalid details and dynamic catalog errors do not reach the sink", %{dir: dir} do
    start_sdk()
    assert {:error, :invalid_catalog} = SDK.catalog([String])
    assert {:error, :invalid_catalog} = SDK.declare_catalog([String])
    [property | _] = elem(SDK.catalog([__MODULE__]), 1)
    assert {:error, :invalid} = SDK.evaluate(property, true, %Details{observed_count: -1})

    assert {:error, :invalid} =
             SDK.evaluate(%{property | message: "Dynamic unreviewed message"}, true, nil)

    refute File.exists?(Path.join(dir, "sdk.jsonl"))
  end

  test "known short write poisons the sink and prevents concatenation", %{dir: dir} do
    System.put_env("OVERALLS_ANTITHESIS_TEST_SHORT_WRITE", "1")
    start_sdk()
    assert {:error, :uncertain} = SDK.setup_complete()
    assert :poisoned = SDK.status()
    assert {:error, :poisoned} = SDK.setup_complete()

    assert File.read!(Path.join(dir, "sdk.jsonl")) ==
             ~s({"antithesis_setup":{"status":"complete"}})

    Application.stop(:overalls_antithesis_sdk)
    start_sdk()
    assert :poisoned = SDK.status()
    assert {:error, :poisoned} = SDK.setup_complete()

    assert File.read!(Path.join(dir, "sdk.jsonl")) ==
             ~s({"antithesis_setup":{"status":"complete"}})
  end

  test "lost acknowledgment times out and poisons even when the write was complete", %{dir: dir} do
    System.put_env("OVERALLS_ANTITHESIS_TEST_DELAY_REPLY", "1")
    start_sdk()
    assert {:error, :timeout} = SDK.setup_complete()
    assert :poisoned = SDK.status()
    assert {:error, :poisoned} = SDK.setup_complete()
    assert File.read!(Path.join(dir, "sdk.jsonl")) |> String.ends_with?("\n")
  end

  test "status reflects disabled and unavailable output configurations" do
    System.delete_env("ANTITHESIS_OUTPUT_DIR")
    start_sdk()
    assert :disabled = SDK.status()
    assert :disabled = SDK.setup_complete()

    Application.stop(:overalls_antithesis_sdk)
    System.put_env("ANTITHESIS_OUTPUT_DIR", "/tmp")
    System.delete_env("OVERALLS_ANTITHESIS_WRITER")
    start_sdk()
    assert :unavailable = SDK.status()
    assert {:error, :unavailable} = SDK.setup_complete()
  end

  test "native helper refuses a malformed frame without touching the local output", %{
    helper: helper,
    dir: dir,
    state_dir: state_dir
  } do
    path = Path.join(dir, "sdk.jsonl")

    port =
      Port.open({:spawn_executable, String.to_charlist(helper)}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, [path, state_dir]}
      ])

    assert Port.command(port, "bad\n")
    assert_receive {^port, {:data, "I"}}, 500
    assert Port.command(port, "{bad}\n")
    assert_receive {^port, {:data, "I"}}, 500
    assert File.read!(path) == ""
    assert Port.command(port, ~s({"antithesis_setup":{"status":"complete"}}\n))
    assert_receive {^port, {:data, "W"}}, 500
    assert File.read!(path) == ~s({"antithesis_setup":{"status":"complete"}}\n)
    Port.close(port)
  end

  test "a second helper refuses the poison marker after a short first write", %{
    helper: helper,
    dir: dir,
    state_dir: state_dir
  } do
    path = Path.join(dir, "sdk.jsonl")
    System.put_env("OVERALLS_ANTITHESIS_TEST_SHORT_WRITE", "1")

    first =
      Port.open({:spawn_executable, String.to_charlist(helper)}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, [path, state_dir]}
      ])

    assert Port.command(first, ~s({"antithesis_setup":{"status":"complete"}}\n))
    assert_receive {^first, {:data, "P"}}, 500
    ref = :erlang.monitor(:port, first)
    Port.close(first)
    assert_receive {:DOWN, ^ref, :port, ^first, _}, 500
    System.delete_env("OVERALLS_ANTITHESIS_TEST_SHORT_WRITE")

    second =
      Port.open({:spawn_executable, String.to_charlist(helper)}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, [path, state_dir]}
      ])

    assert_receive {^second, {:exit_status, 5}}, 500
    assert File.read!(path) == ~s({"antithesis_setup":{"status":"complete"}})
  end

  test "choice returns a member using fresh device reads" do
    assert {:ok, :only} = SDK.choose([:only])
    assert {:ok, choice} = SDK.choose([:a, :b, :c])
    assert choice in [:a, :b, :c]
    assert {:error, :random_unavailable} = SDK.choose([])
  end

  defp start_sdk do
    assert {:ok, _} = Application.ensure_all_started(:overalls_antithesis_sdk)
  end
end
