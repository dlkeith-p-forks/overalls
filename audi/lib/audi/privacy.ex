defmodule Audi.Privacy do
  @moduledoc "Redact OTP and SSH diagnostics at the source, before any logger handler."

  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(:audi_privacy, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, :audi_privacy}} -> :ok
    end
  end

  # @cc [owner:ghuntley,label:security] audi-source-report-redaction
  # Every structured OTP report and format/argument diagnostic MUST be reduced
  # to a fixed category before handlers can inspect it. SSH-domain or explicitly
  # unclassified private string diagnostics MUST also lose all original text and metadata.
  # Process state, mailbox contents and formatter callbacks MUST NOT survive.
  # Reviewed operational events MUST be reconstructed from the Audi.Events
  # catalog with fixed text and its declared identifier, numeric and finite
  # enum shapes, never preserve
  # arbitrary message text/metadata.
  @catalog Audi.Events.__catalog__()
  @components [:acme, :dns, :http, :https, :private, :ssh, :status]
  @phases [:http_data, :http_info, :http_init]
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
        meta: safe |> Map.merge(selected) |> Map.put(:event, name) |> Map.put(:domain, [:audi])
    }
  end

  # @cc [owner:ghuntley,label:observability] audi-drop-supervisor-progress
  # OTP supervisor progress reports MUST be dropped: :ssl starts children for
  # every TLS connection, so they were the bulk of Audi's log volume and carry
  # no operational signal. Crash and supervisor-failure reports are retained.
  def filter(%{msg: {:report, %{label: {:supervisor, :progress}}}}, _), do: :stop

  def filter(%{msg: {:report, report}} = event, _), do: redact(event, category(report))

  def filter(%{msg: {format, _arguments}} = event, _) when is_list(format) or is_binary(format),
    do: redact(event, "runtime_report")

  def filter(%{meta: %{audi_private: true}} = event, _),
    do: redact(event, "private_diagnostic")

  def filter(%{meta: %{domain: [:otp, :ssh | _]}} = event, _), do: redact(event, "ssh_runtime")
  def filter(_, _), do: :ignore

  defp redact(event, category) do
    metadata =
      event
      |> Map.get(:meta, %{})
      |> Map.take([:time, :pid, :gl, :audi_component, :audi_phase])
      |> runtime_metadata()

    name = "audi." <> category
    message = get_in(@catalog, [name, :message]) || "Audi " <> category <> " (payload redacted)"

    %{
      event
      | msg: {:string, message},
        meta:
          Map.merge(metadata, %{
            domain: [:audi],
            event: name,
            report_category: category
          })
    }
  end

  # @cc [owner:ghuntley,label:security;observability] audi-runtime-component-enum
  # Runtime report attribution MUST retain only this module's closed component
  # and phase atom vocabularies. Arbitrary process metadata and dependency
  # labels MUST stay redacted even when a crashing process supplies them.
  defp runtime_metadata(metadata) do
    metadata
    |> approved(:audi_component, :component, @components)
    |> approved(:audi_phase, :phase, @phases)
  end

  defp approved(metadata, source, target, allowed) do
    case Map.pop(metadata, source) do
      {value, metadata} ->
        if value in allowed, do: Map.put(metadata, target, value), else: metadata
    end
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
