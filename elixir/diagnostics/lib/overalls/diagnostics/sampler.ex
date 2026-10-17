defmodule Overalls.Diagnostics.Sampler do
  @moduledoc false
  @behaviour :otel_sampler
  @custody_events ["lilly.lifecycle_transition_committed"]
  @type config :: %{routine: :otel_sampler.t(), custody: :otel_sampler.t()}

  @impl true
  @spec setup(map()) :: config()
  def setup(_options) do
    ratio =
      case Float.parse(System.get_env("OVERALLS_TRACE_SAMPLE_RATIO", "1.0")) do
        {ratio, ""} when ratio >= 0.0 and ratio <= 1.0 -> ratio
        _ -> 0.0
      end

    %{
      routine: :otel_sampler.new({:parent_based, %{root: {:trace_id_ratio_based, ratio}}}),
      custody: :otel_sampler.new(:always_on)
    }
  end

  @impl true
  @spec description(config()) :: binary()
  def description(_config), do: "Overalls reviewed custody/parent ratio sampler"

  # @cc [owner:ghuntley,label:recovery;capacity] lifecycle-independent-of-routine-sampling
  # Committed/imported custody observations MUST always be sampled. Routine
  # ratio selection MUST use the official SDK sampler, never affect accounting.
  @impl true
  @spec should_sample(
          :otel_ctx.t(),
          :opentelemetry.trace_id(),
          :otel_links.t(),
          :opentelemetry.span_name(),
          :opentelemetry.span_kind(),
          :opentelemetry.attributes_map(),
          config()
        ) :: :otel_sampler.sampling_result()
  def should_sample(context, trace_id, links, name, kind, attributes, config) do
    sampler =
      if name in @custody_events or
           Process.get({Overalls.Diagnostics.Custody, :mode}) == :enqueue,
         do: config.custody,
         else: config.routine

    :otel_sampler.should_sample(sampler, context, trace_id, links, name, kind, attributes)
  end
end
