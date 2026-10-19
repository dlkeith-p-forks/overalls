defmodule Marshall.Operations.MigrateTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Operations.Migrate

  # @cc [owner:ghuntley,label:verification;security] migration-errors-exclude-private-data
  # Generated exception payloads MUST NOT affect the closed diagnostic projection.
  # Unknown PostgreSQL codes MUST remain opaque instead of becoming log metadata.
  property "migration failure diagnostics retain only reviewed categories and codes" do
    private = Hegel.draw("private exception data", binary(max_length: 128))

    code =
      Hegel.draw(
        "reviewed database failure",
        member_of([:too_many_connections, :duplicate_table, :query_canceled])
      )

    error = %Postgrex.Error{
      message: private,
      postgres: %{code: code, message: private, detail: private},
      query: private
    }

    assert Migrate.failure_diagnostic(error) == %{exception_class: :postgrex, postgres_code: code}

    for unknown <- [private, :unreviewed_database_failure, nil] do
      assert Migrate.failure_diagnostic(%{error | postgres: %{code: unknown, message: private}}) ==
               %{exception_class: :postgrex, postgres_code: :unknown}
    end

    for {exception, category} <- [
          {%DBConnection.ConnectionError{message: private}, :connection},
          {%Ecto.MigrationError{message: private}, :migration},
          {%RuntimeError{message: private}, :runtime},
          {%ArgumentError{message: private}, :argument},
          {%MatchError{term: private}, :match},
          {%{message: private, code: code}, :unknown}
        ] do
      assert Migrate.failure_diagnostic(exception) ==
               %{exception_class: category, postgres_code: :unknown}
    end
  end
end
