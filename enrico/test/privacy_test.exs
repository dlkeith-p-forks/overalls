defmodule Enrico.PrivacyTest do
  use ExUnit.Case, async: true

  test "crash reports retain their category and discard content before handlers" do
    clean =
      Enrico.Privacy.filter(
        %{
          level: :error,
          msg: {:report, %{label: {:gen_server, :terminate}, state: "private-canary"}},
          meta: %{credential: "private-canary", report_cb: fn _ -> "private-canary" end}
        },
        nil
      )

    assert clean.meta.event == "enrico.process_crash"
    assert clean.meta.report_category == :process_crash
    refute inspect(clean) =~ "private-canary"
    refute Map.has_key?(clean.meta, :report_cb)
  end
end
