defmodule Marshall.Operations.InvalidRuntimeBootPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  @project Path.expand("../../..", __DIR__)
  @probe Path.join(@project, "scripts/invalid_runtime_boot_probe.exs")
  @numeric_cases Enum.flat_map(
                   [
                     {"MARSHALL_INFERENCE_DETAIL_DAYS", 36_500},
                     {"MARSHALL_INFERENCE_AGGREGATE_DAYS", 36_500},
                     {"MARSHALL_INGRESS_HTTPS_PORT", 65_535},
                     {"MARSHALL_RELOCATION_READINESS_TIMEOUT_MS", 600_000}
                   ],
                   fn {name, maximum} ->
                     Enum.map(["", "-1", "0", "#{maximum + 1}", "1x", " 1"], &{name, &1})
                   end
                 )
  @image_cases Enum.flat_map(
                 ["MARSHALL_DEFAULT_IMAGE_ID", "MARSHALL_INCEPTION_IMAGE_ID"],
                 fn name ->
                   Enum.map(
                     [
                       "sha256:" <> String.duplicate("a", 63),
                       "sha256:" <> String.duplicate("a", 65),
                       "sha256:" <> String.duplicate("A", 64),
                       "sha512:" <> String.duplicate("a", 64),
                       "private-material"
                     ],
                     &{name, &1}
                   )
                 end
               )
  @cases @numeric_cases ++ @image_cases
  @outcomes %{
    "MARSHALL_INFERENCE_DETAIL_DAYS" => "retention_rejected",
    "MARSHALL_INFERENCE_AGGREGATE_DAYS" => "retention_rejected",
    "MARSHALL_INGRESS_HTTPS_PORT" => "ingress_port_rejected",
    "MARSHALL_RELOCATION_READINESS_TIMEOUT_MS" => "readiness_rejected",
    "MARSHALL_DEFAULT_IMAGE_ID" => "default_image_rejected",
    "MARSHALL_INCEPTION_IMAGE_ID" => "inception_image_rejected"
  }
  @valid_outcomes Map.values(@outcomes) ++ ["started", "configured", "other"]
  @type projection :: %{
          String.t() => String.t() | boolean()
        }

  # @cc [owner:ghuntley,label:verification;security] marshall-runtime-refusal-scope
  # Every generated history MUST exercise each common runtime mutation through
  # a fresh real Mix app.start boundary before application callbacks. Reader
  # controls MUST use app.config only and MUST NOT establish configured serving
  # or production-release acceptance. Child diagnostics MUST omit fixture data.
  @tag timeout: 300_000
  property "invalid common Marshall runtime settings refuse before application startup" do
    check all(order <- shuffle(Enum.to_list(0..(length(@cases) - 1))), max_runs: 3) do
      for index <- order do
        {name, value} = Enum.at(@cases, index)

        material =
          "private_boot_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        mutated = if value == "private-material", do: material, else: value

        {projection, output} = probe("refusal", [{name, mutated}])

        assert projection == %{
                 "outcome" => Map.fetch!(@outcomes, name),
                 "startup_attempted" => false,
                 "trace_calibrated" => true,
                 "serving_present" => false,
                 "application_started" => false
               },
               "case #{index}: #{inspect(projection)}"

        refute String.contains?(output, material)
        refute String.contains?(output, @project)
      end
    end
  end

  test "valid common Marshall runtime settings load without starting the application" do
    for values <- [
          [],
          [
            {"MARSHALL_INFERENCE_DETAIL_DAYS", "1"},
            {"MARSHALL_INFERENCE_AGGREGATE_DAYS", "36500"},
            {"MARSHALL_INGRESS_HTTPS_PORT", "65535"},
            {"MARSHALL_RELOCATION_READINESS_TIMEOUT_MS", "600000"},
            {"MARSHALL_DEFAULT_IMAGE_ID", "sha256:" <> String.duplicate("a", 64)},
            {"MARSHALL_INCEPTION_IMAGE_ID", ""}
          ]
        ] do
      {projection, _} = probe("reader", values)

      assert projection == %{
               "outcome" => "configured",
               "startup_attempted" => false,
               "trace_calibrated" => true,
               "serving_present" => false,
               "application_started" => false
             }
    end
  end

  @spec probe(String.t(), [{String.t(), String.t()}]) :: {projection(), String.t()}
  defp probe(mode, values) do
    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(fn name ->
        String.starts_with?(name, ["MARSHALL_", "PHX_"]) or
          name in [
            "PORT",
            "SECRET_KEY_BASE",
            "TOKEN_SIGNING_SECRET",
            "DNS_CLUSTER_QUERY",
            "MIX_ENV",
            "MIX_TEST_PARTITION"
          ]
      end)
      |> Enum.map(&{&1, nil})

    environment =
      cleared ++
        [
          {"MIX_ENV", "test"},
          {"PHX_SERVER", "false"},
          {"OVERALLS_BOOT_PROBE", "test"},
          {"OVERALLS_PROBE_PROJECT", @project},
          {"OVERALLS_PROBE_MODE", mode},
          {"OVERALLS_PROBE_INPUT", JSON.encode!(Map.new(values))}
        ]

    {output, status} =
      System.cmd("elixir", ["--erl", "+S 2:2", @probe],
        cd: @project,
        env: environment |> Map.new() |> Map.to_list(),
        stderr_to_stdout: true
      )

    assert status == 0
    [encoded] = for "BOOT_PROBE:" <> encoded <- String.split(output, "\n"), do: encoded
    assert {:ok, projection} = JSON.decode(encoded)

    case projection do
      %{
        "outcome" => outcome,
        "startup_attempted" => attempted,
        "trace_calibrated" => calibrated,
        "serving_present" => present,
        "application_started" => started
      }
      when map_size(projection) == 5 and is_boolean(calibrated) and outcome in @valid_outcomes and
             is_boolean(attempted) and
             is_boolean(present) and is_boolean(started) ->
        {%{
           "outcome" => outcome,
           "startup_attempted" => attempted,
           "trace_calibrated" => calibrated,
           "serving_present" => present,
           "application_started" => started
         }, output}

      _ ->
        flunk("invalid early boot projection")
    end
  end
end
