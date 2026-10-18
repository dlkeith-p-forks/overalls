defmodule Marshall.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Marshall.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Marshall.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Marshall.DataCase
    end
  end

  setup tags do
    Marshall.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  # @cc [owner:ghuntley,label:verification] sandbox-owner-lifetime
  # setup_sandbox/1 MUST stop the SQL sandbox owner on test exit and MUST NOT
  # share a connection across concurrently running asynchronous test cases.

  # @cc [owner:ghuntley,label:verification] sandbox-owner-timeout-override
  # An explicit ownership_timeout test tag MUST be an integer from 1 to 240000
  # milliseconds and MUST be forwarded to the sandbox owner. Invalid tags MUST
  # raise before starting an owner; an absent tag MUST preserve Ecto's configured
  # ownership timeout.
  @spec setup_sandbox(%{required(:async) => boolean(), optional(atom()) => term()}) :: :ok
  def setup_sandbox(%{hegel_case_sandbox: true, async: false}), do: :ok

  def setup_sandbox(%{hegel_case_sandbox: true}) do
    raise ArgumentError, "per-case shared SQL sandboxes require a synchronous test"
  end

  def setup_sandbox(tags) do
    options = [shared: not tags[:async]]

    options =
      case Map.fetch(tags, :ownership_timeout) do
        :error ->
          options

        {:ok, timeout} when is_integer(timeout) and timeout in 1..240_000 ->
          Keyword.put(options, :ownership_timeout, timeout)

        {:ok, _invalid} ->
          raise ArgumentError,
                "ownership_timeout test tag must be an integer from 1 to 240000 milliseconds"
      end

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Marshall.Repo, options)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  # @cc [owner:ghuntley,label:verification] generated-sandbox-case-isolation
  # Tests tagged hegel_case_sandbox MUST be synchronous and create a fresh owner for each generated
  # case and stop it before replay or the next case. Register this before process
  # fixtures so their cleanup runs first. Committed/distributed tests retain
  # their explicit owned-row cleanup instead; they MUST NOT use this helper.
  @spec isolate_property_case() :: :ok
  def isolate_property_case do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Marshall.Repo, shared: true)
    Hegel.on_cleanup(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
