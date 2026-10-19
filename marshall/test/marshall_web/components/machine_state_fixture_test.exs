defmodule MarshallWeb.Components.MachineStateFixtureTest do
  use ExUnit.Case, async: true
  alias MarshallWeb.WorkspaceComponents

  # Shared with Mila so the app labels every state pair exactly as the web does.
  @fixture Path.expand("../../../../protocol/test/fixtures/machine_states.json", __DIR__)
  @external_resource @fixture

  test "every desired/observed pair matches the shared label and tone fixture" do
    %{"version" => 1, "states" => states} = @fixture |> File.read!() |> JSON.decode!()
    assert length(states) == 4 * 7

    Gettext.with_locale(MarshallWeb.Gettext, "en", fn ->
      for %{"desired_state" => desired, "observed_state" => observed} = row <- states do
        vm = %{
          desired_state: String.to_existing_atom(desired),
          observed_state: String.to_existing_atom(observed)
        }

        assert WorkspaceComponents.machine_state(vm) == row["label"], inspect(row)
        assert WorkspaceComponents.machine_tone(vm) == row["tone"], inspect(row)
      end
    end)
  end
end
