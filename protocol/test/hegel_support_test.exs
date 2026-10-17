defmodule OverallsProtocol.HegelSupportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import OverallsProtocol.TestProperties, only: [draw: 2]

  require Hegel

  test "native failure replay redacts draws and preserves the original exception" do
    synthetic_payload = "isolated-terminal-payload-must-stay-private"

    output =
      capture_io(:stderr, fn ->
        assert_raise RuntimeError, "fixture failure", fn ->
          Hegel.check(
            fn ->
              draw("payload", Hegel.Gen.constant(synthetic_payload))
              raise "fixture failure"
            end,
            database: :disabled,
            print_blob: false,
            test_cases: 1,
            seed: 20_261_110
          )
        end
      end)

    assert output =~ "payload = <redacted>"
    refute output =~ synthetic_payload
  end
end
