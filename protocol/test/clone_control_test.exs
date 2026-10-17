defmodule OverallsProtocol.CloneControlTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.CloneControl

  defp id(n) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
  end

  defp exchange(results) do
    %{"version" => 5, "session_id" => id(1), "epoch" => 3, "results" => results}
  end

  defp result(kind, result) do
    %{"id" => id(2), "kind" => kind, "result" => result}
  end

  # @cc [owner:ghuntley,label:verification;protocol] clone-unconfirmed-reason-closed-tested
  # Generated unconfirmed results MUST be accepted for every kind and closed
  # reason and refused for a missing, unknown or decorated reason.
  property "an unconfirmed result is accepted only with one closed reason",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 64_464_244 do
    kind = draw("kind", member_of(CloneControl.kinds()))
    reason = draw("reason", member_of(CloneControl.unconfirmed_reasons()))
    wire = result(kind, %{"error" => "unconfirmed", "reason" => reason})
    assert {:ok, ^wire} = CloneControl.result(wire)
    assert {:ok, %{results: [^wire]}} = CloneControl.exchange(exchange([wire]))
  end

  property "unconfirmed results without a closed reason are invalid",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 566_361_442 do
    kind = draw("kind", member_of(CloneControl.kinds()))

    stray =
      draw(
        "stray",
        one_of([
          constant(%{"error" => "unconfirmed"}),
          map(
            OverallsProtocol.TestGenerators.string(:alphanumeric, min_length: 1),
            &%{"error" => "unconfirmed", "reason" => "#{&1}_unknown"}
          ),
          map(
            member_of(CloneControl.unconfirmed_reasons()),
            &%{"error" => "unconfirmed", "reason" => &1, "detail" => "native output"}
          ),
          map(member_of(CloneControl.unconfirmed_reasons()), &%{"reason" => &1})
        ])
      )

    assert {:error, :invalid_message} = CloneControl.result(result(kind, stray))
  end

  test "the exchange envelope is version five and closed" do
    wire = exchange([])
    assert {:ok, %{session_id: session, epoch: 3, results: []}} = CloneControl.exchange(wire)
    assert session == id(1)
    assert {:error, :invalid_message} = CloneControl.exchange(%{wire | "version" => 4})
    assert {:error, :invalid_message} = CloneControl.exchange(Map.put(wire, "host_id", id(4)))
  end
end
