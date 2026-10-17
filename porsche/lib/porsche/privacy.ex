defmodule Porsche.Privacy do
  @moduledoc "Redact OTP and SSH diagnostics at the source, before any logger handler."
  @catalog Porsche.Events.__catalog__()

  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(:porsche_privacy, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, :porsche_privacy}} -> :ok
    end
  end

  # @cc [owner:ghuntley,label:security] porsche-source-report-redaction
  # Every structured OTP report and format/argument diagnostic MUST be reduced
  # to a fixed category before handlers can inspect it. SSH-domain or explicitly
  # private string diagnostics MUST also lose all original text and metadata.
  # Process state, mailbox contents and formatter callbacks MUST NOT survive.
  # Reviewed catalog events are the only informative exception: they MUST be
  # reconstructed from catalog text with only catalogued, shape-validated
  # metadata; every other field of the original event MUST be discarded.
  @spec filter(map(), term()) :: map() | :ignore
  def filter(%{msg: {:string, _}, meta: %{event: name}} = event, _)
      when is_map_key(@catalog, name) do
    spec = Map.fetch!(@catalog, name)
    selected = Overalls.Diagnostics.Events.Catalog.safe_metadata(spec.metadata, event.meta)

    safe =
      Map.take(event.meta, [:time, :pid, :gl])
      |> Map.merge(Overalls.Diagnostics.Context.log_context(event.meta))

    %{
      event
      | msg: {:string, spec.message},
        meta: safe |> Map.merge(selected) |> Map.put(:event, name) |> Map.put(:domain, [:porsche])
    }
  end

  def filter(%{msg: {:report, report}} = event, _), do: redact(event, category(report))

  def filter(%{msg: {format, _arguments}} = event, _) when is_list(format) or is_binary(format),
    do: redact(event, "runtime_report")

  def filter(%{meta: %{porsche_private: true}} = event, _),
    do: redact(event, "private_diagnostic")

  def filter(%{meta: %{domain: [:otp, :ssh | _]}} = event, _), do: redact(event, "ssh_runtime")
  def filter(_, _), do: :ignore

  defp redact(event, category) do
    metadata =
      event
      |> Map.get(:meta, %{})
      |> Map.take([:time, :pid, :gl])
      |> Map.merge(Overalls.Diagnostics.Context.log_context(Map.get(event, :meta, %{})))

    %{
      event
      | msg: {:string, "Porsche " <> category <> " (payload redacted)"},
        meta:
          Map.merge(metadata, %{
            domain: [:porsche],
            event: "porsche." <> category,
            report_category: category
          })
    }
  end

  defp category(%{label: label}) do
    case label do
      {:gen_server, :terminate} -> "process_crash"
      {:gen_statem, :terminate} -> "process_crash"
      {:proc_lib, :crash} -> "process_crash"
      {Task.Supervisor, :terminating} -> "process_crash"
      {:supervisor, :progress} -> "supervisor_started"
      {:supervisor, _} -> "supervisor_report"
      _ -> "runtime_report"
    end
  end

  defp category(_), do: "runtime_report"
end
