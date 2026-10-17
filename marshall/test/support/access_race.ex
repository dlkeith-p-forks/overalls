defmodule Marshall.AccessRace do
  @moduledoc false
  @spec lifecycle(String.t(), map(), Marshall.Accounts.User.t()) :: term()
  def lifecycle(tag, params, actor) do
    Marshall.Repo.checkout(fn ->
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT set_config('application_name', $1, false)",
        [tag],
        log: false
      )

      try do
        Marshall.Compute.lifecycle(params, actor: actor)
      after
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT set_config('application_name', '', false)",
          [],
          log: false
        )
      end
    end)
  end
end
