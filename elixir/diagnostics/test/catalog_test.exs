defmodule Overalls.Diagnostics.CatalogTest do
  use ExUnit.Case, async: false

  defmodule Catalog do
    use Overalls.Diagnostics.Events.Catalog, service: :lilly

    defevent("lilly.catalog_test",
      message: "Fixed reviewed test",
      metadata: [
        count: :int64,
        outcome: {{:enum, [:ok, :error]}, :optional},
        host_id: {:uuid, :optional}
      ]
    )
  end

  test "optional closed enums and exact nonnegative int64 validate without exposing rejected values" do
    assert Catalog.__validate__(:int64, 9_223_372_036_854_775_807, false) ==
             9_223_372_036_854_775_807

    assert Catalog.__validate__({:enum, [:ok, :error]}, :ok, false) == :ok
    assert Catalog.__validate__({:enum, [:ok, :error]}, nil, true) == :drop

    for value <- [-1, 9_223_372_036_854_775_808, "secret"] do
      assert_raise ArgumentError, ~r/offending value redacted/, fn ->
        Catalog.__validate__(:int64, value, false)
      end
    end

    assert_raise ArgumentError, ~r/offending value redacted/, fn ->
      Catalog.__validate__({:enum, [:ok]}, :unreviewed, false)
    end

    assert_raise ArgumentError, ~r/offending value redacted/, fn ->
      Catalog.__validate__(:atom, :unreviewed_observer_enum, false)
    end
  end

  test "duplicate declarations and emission keys fail before any emission" do
    assert_raise ArgumentError, ~r/duplicate event metadata/, fn ->
      compile(
        "defevent(\"lilly.duplicate\",message: \"fixed\",metadata: [count: :int,count: :int])"
      )
    end

    assert_raise ArgumentError, ~r/duplicate structured event declaration/, fn ->
      compile(
        "defevent(\"lilly.duplicate\",message: \"fixed\");defevent(\"lilly.duplicate\",message: \"fixed\")"
      )
    end

    assert_raise ArgumentError, ~r/duplicate structured event emission/, fn ->
      Code.compile_string(
        "defmodule Overalls.Diagnostics.CatalogDuplicateCaller do\nrequire Overalls.Diagnostics.CatalogTest.Catalog\nOveralls.Diagnostics.CatalogTest.Catalog.emit(\"lilly.catalog_test\",count: 1,count: 2)\nend"
      )
    end
  end

  test "routine sampling can be disabled while immutable lifecycle remains sampled" do
    previous = System.get_env("OVERALLS_TRACE_SAMPLE_RATIO")
    System.put_env("OVERALLS_TRACE_SAMPLE_RATIO", "0.0")

    try do
      config = Overalls.Diagnostics.Sampler.setup(%{})

      assert {:drop, _, _} =
               Overalls.Diagnostics.Sampler.should_sample(
                 :otel_ctx.new(),
                 1,
                 [],
                 "lilly.host.utility",
                 :internal,
                 %{},
                 config
               )

      assert {:record_and_sample, _, _} =
               Overalls.Diagnostics.Sampler.should_sample(
                 :otel_ctx.new(),
                 1,
                 [],
                 "lilly.lifecycle_transition_committed",
                 :internal,
                 %{},
                 config
               )
    after
      if previous,
        do: System.put_env("OVERALLS_TRACE_SAMPLE_RATIO", previous),
        else: System.delete_env("OVERALLS_TRACE_SAMPLE_RATIO")
    end
  end

  test "source reconstruction drops untyped injected values and preserves reviewed numeric fields" do
    declared = Catalog.__catalog__()["lilly.catalog_test"].metadata

    assert Overalls.Diagnostics.Events.Catalog.safe_metadata(declared, %{
             count: 3_000_000_000,
             outcome: :ok,
             host_id: "not-a-uuid",
             payload: "secret"
           }) == %{count: 3_000_000_000, outcome: :ok}

    assert Overalls.Diagnostics.Context.log_context(:undefined) == %{}

    assert Overalls.Diagnostics.Context.log_context(%{
             trace_id: String.duplicate("0", 32),
             span_id: "secret"
           }) == %{}
  end

  @spec compile(binary()) :: [{module(), binary()}]
  defp compile(body) do
    module = "Overalls.Diagnostics.GeneratedCatalog#{System.unique_integer([:positive])}"

    Code.compile_string(
      "defmodule #{module} do\nuse Overalls.Diagnostics.Events.Catalog,service: :lilly\n#{body}\nend"
    )
  end
end
