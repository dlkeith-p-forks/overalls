defmodule Marshall.OTPReports do
  @moduledoc "Sanitize OTP reports before their default translator can inspect process data."
  @behaviour Logger.Translator

  # @cc [owner:ghuntley,label:security] otp-report-no-process-data
  # Translation MUST retain only fixed report categories. Startup arguments,
  # exit reasons, messages, state and queued terminal data MUST NOT be formatted.
  @impl true
  def translate(_minimum, _level, :report, {:logger, %{label: label}}), do: report(label)
  def translate(_minimum, _level, :report, {label, _data}), do: report(label)
  def translate(_minimum, _level, :format, _message), do: report(:formatted)
  def translate(_, _, _, _), do: :none

  @spec install() :: :ok
  def install, do: Logger.add_translator({__MODULE__, :translate})

  defp report(label) do
    category =
      case label do
        {:supervisor, :progress} -> "supervisor_started"
        {:supervisor, _} -> "supervisor_report"
        {:application_controller, :progress} -> "application_started"
        {:application_controller, :exit} -> "application_exit"
        {:proc_lib, :crash} -> "process_crash"
        {:gen_server, :terminate} -> "process_crash"
        {:gen_statem, :terminate} -> "process_crash"
        {:gen_event, :terminate} -> "process_crash"
        {Task.Supervisor, :terminating} -> "task_crash"
        :crash_report -> "process_crash"
        :supervisor_report -> "supervisor_report"
        _ -> "runtime_report"
      end

    {:ok, "OTP " <> category <> " (process data redacted)",
     [event: "otp." <> category, report_category: category]}
  end
end
