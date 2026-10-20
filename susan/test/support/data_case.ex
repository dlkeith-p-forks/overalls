defmodule Susan.DataCase do
  @moduledoc "Sandboxed database ownership for tests that touch Susan's repository."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Susan.DataCase
      alias Susan.Fixtures
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Susan.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Susan.FakeProvider.reset()
    # Provider tokens are cached process-wide; each test starts without one.
    Enum.each([:apns, :fcm, :wns], &Susan.Provider.Tokens.invalidate/1)
    :ok
  end
end
