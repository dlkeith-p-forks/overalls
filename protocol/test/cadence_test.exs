defmodule OverallsProtocol.CadenceTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Cadence

  # Model: `in_flight` runs, and whether a request arrived after the current
  # run started. A run that finishes with a pending request must be followed at
  # once by another run; a tick during a run never starts or schedules one, and
  # requests during a run never start more than one follow-up.
  property "single flight, no lost request, no back-to-back periodic run, no backlog" do
    check all(events <- list_of(member_of([:tick, :request, :done]), max_length: 200)) do
      {_cadence, _model} =
        Enum.reduce(events, {Cadence.new(), %{in_flight: 0, pending: false}}, fn event,
                                                                                 {cadence, model} ->
          case Cadence.step(cadence, event) do
            {:ok, next, effects} ->
              starts = Enum.count(effects, &(&1 == :start))
              model = apply_model(model, event, starts)
              assert model.in_flight <= 1
              assert Cadence.running?(next) == (model.in_flight == 1)
              {next, model}

            {:error, :invalid_transition} ->
              # Only a completion with nothing in flight may be refused.
              assert event == :done and model.in_flight == 0
              {cadence, model}
          end
        end)
    end
  end

  test "ticks during a run are dropped: completion rests until the next tick" do
    {:ok, c, [:start]} = Cadence.step(Cadence.new(), :tick)
    {:ok, c, []} = Cadence.step(c, :tick)
    {:ok, c, []} = Cadence.step(c, :tick)
    assert {:ok, %Cadence{state: :idle} = c, []} = Cadence.step(c, :done)
    assert {:ok, _c, [:start]} = Cadence.step(c, :tick)
  end

  test "a request during a run starts exactly one follow-up run on completion" do
    {:ok, c, [:start]} = Cadence.step(Cadence.new(), :tick)
    {:ok, c, []} = Cadence.step(c, :request)
    {:ok, c, []} = Cadence.step(c, :tick)
    {:ok, c, []} = Cadence.step(c, :request)
    assert {:ok, c, [:start]} = Cadence.step(c, :done)
    assert {:ok, %Cadence{state: :idle}, []} = Cadence.step(c, :done)
  end

  defp apply_model(model, event, starts) when event in [:tick, :request] do
    cond do
      model.in_flight == 0 ->
        assert starts == 1
        %{model | in_flight: 1}

      event == :tick ->
        assert starts == 0
        model

      true ->
        assert starts == 0
        %{model | pending: true}
    end
  end

  defp apply_model(model, :done, starts) do
    assert model.in_flight == 1

    if model.pending do
      assert starts == 1, "a request during the run must start the next run on completion"
      %{model | pending: false}
    else
      assert starts == 0, "a periodic tick during the run must not start a follow-up"
      %{model | in_flight: 0}
    end
  end
end
