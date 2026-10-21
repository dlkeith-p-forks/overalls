defmodule Lilly.DiagnosticStatus do
  @moduledoc "Payload-free OTP status formatting with explicit public state projections."

  # @cc [owner:ghuntley,label:security;observability] diagnostic-status-retains-otp-keys
  # OTP status callbacks MUST retain every input key so OTP accepts the result.
  # Only an explicitly reviewed state projection may survive; messages, reasons,
  # debug logs and future fields MUST NOT expose private payloads.
  @spec redact(map(), map() | :redacted) :: map()
  def redact(status, public_state \\ :redacted) do
    Map.new(status, fn
      {:state, _} -> {:state, public_state}
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end
end
