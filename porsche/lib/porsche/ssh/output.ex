defmodule Porsche.SSH.Output do
  @moduledoc "Single-result channel output, separate from bounded progress messages."
  use Gettext, backend: Porsche.Gettext

  # @cc [owner:ghuntley,label:security;protocol] porsche-terminal-result-framing
  # JSON output MUST decode to the original response as one newline-terminated
  # object. Peer-provided control characters MUST be escaped in both output
  # modes, including nested strings and Unicode C1/line-separator controls.
  @spec render(map(), boolean()) :: binary()
  def render(response, true), do: encode(response) <> "\n"

  def render(%{"result" => %{"commands" => commands}} = response, false) when is_list(commands) do
    rows =
      for %{"usage" => usage, "summary" => summary} <- commands,
          is_binary(usage) and is_binary(summary),
          do: safe(usage) <> "\n  " <> safe(Gettext.gettext(Porsche.Gettext, summary))

    if rows == [], do: human(response), else: Enum.join(rows, "\n") <> "\n"
  end

  def render(
        %{"status" => "approval_required", "fingerprint" => fingerprint, "approval_url" => url},
        false
      )
      when is_binary(fingerprint) and is_binary(url),
      do: Porsche.SSH.Onboarding.approval(fingerprint, url)

  def render(%{"status" => "error", "error" => reason}, false) when is_binary(reason),
    do: error_message(reason) <> "\n"

  def render(response, false), do: human(response)

  # @cc [owner:ghuntley,label:security;protocol] porsche-exec-approval-lifetime
  # Human exec rejections MUST direct users to a live interactive connection,
  # not display a link invalidated by that exec's disconnect. JSON framing and
  # pending approval data MUST remain unchanged for multiplexed clients.
  @spec render(map(), boolean(), :interactive | {:exec, binary()}) :: binary()
  def render(
        %{"status" => "approval_required", "fingerprint" => fingerprint},
        false,
        {:exec, origin}
      )
      when is_binary(fingerprint),
      do: Porsche.SSH.Onboarding.retry_interactively(fingerprint, origin)

  def render(response, json, _context), do: render(response, json)

  @spec error_message(String.t()) :: String.t()
  defp error_message(reason) do
    case reason do
      "unauthorized" ->
        gettext("This connection is not authorized. Please sign in and try again.")

      "forbidden" ->
        gettext("You do not have permission to perform this action.")

      "invalid_command" ->
        gettext("Invalid command. Type help to see available commands.")

      "temporarily_unavailable" ->
        gettext("The service is temporarily unavailable. Please try again shortly.")

      "approval_required" ->
        gettext("Approve this SSH key in your browser, then retry the command.")

      "not_found" ->
        gettext("The requested resource could not be found.")

      "unexpected_input" ->
        gettext("Unexpected input. Please open a new SSH connection.")

      _ ->
        gettext("The command could not be completed: %{reason}", reason: safe(reason))
    end
  end

  defp human(response) do
    response
    |> Enum.sort()
    |> Enum.map_join("\n", fn {key, value} -> safe(key) <> ": " <> value(value) end)
    |> Kernel.<>("\n")
  end

  defp value(text) when is_binary(text), do: safe(text)
  defp value(value), do: encode(value)

  defp encode(value) do
    value
    |> JSON.encode!()
    |> String.replace(
      ~r/[\x{007f}-\x{009f}\x{2028}\x{2029}]/u,
      fn <<point::utf8>> -> "\\u" <> String.pad_leading(Integer.to_string(point, 16), 4, "0") end
    )
  end

  defp safe(text) do
    String.replace(text, ~r/[\x{0000}-\x{001f}\x{007f}-\x{009f}\x{2028}\x{2029}]/u, fn control ->
      control |> encode() |> String.slice(1..-2//1)
    end)
  end

  @spec progress(map()) :: binary()
  def progress(%{event: :submitting, request_id: id}),
    do: gettext("Request %{id}: submitting", id: safe(id)) <> "\n"

  def progress(%{event: :waiting, request_id: id}),
    do: gettext("Request %{id}: waiting for completion", id: safe(id)) <> "\n"
end
