defmodule Porsche.SSH.Onboarding do
  use Gettext, backend: Porsche.Gettext
  @moduledoc "Shared, bounded SSH onboarding vocabulary and terminal guidance."
  @approval_ttl_seconds 600
  @spec approval_ttl_seconds() :: pos_integer()
  def approval_ttl_seconds, do: @approval_ttl_seconds

  @type key_status :: :recognized | :unknown
  @type diagnosis :: key_status() | :unavailable | :denied

  @spec decode_status(term()) :: {:ok, key_status()} | {:error, :invalid_message}
  def decode_status(%{"version" => 1, "result" => %{"status" => status} = result} = value)
      when map_size(value) == 2 and map_size(result) == 1 do
    case status do
      "recognized" -> {:ok, :recognized}
      "unknown" -> {:ok, :unknown}
      _ -> {:error, :invalid_message}
    end
  end

  def decode_status(_), do: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:security] porsche-guidance-public-origin
  # Guidance origins MUST be bounded HTTPS origins without userinfo, query,
  # fragment or path. Their hosts MUST be safe literal SSH command operands.
  @spec public_origin?(term()) :: boolean()
  def public_origin?(origin) when is_binary(origin) and byte_size(origin) <= 253 do
    case URI.parse(origin) do
      %URI{
        scheme: "https",
        host: host,
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and path in [nil, ""] and port in 1..65_535 ->
        Regex.match?(~r/\Ahttps:\/\/[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?\z/, origin)

      _ ->
        false
    end
  end

  def public_origin?(_), do: false

  # @cc [owner:ghuntley,label:security;protocol] porsche-guidance-terminal-boundary
  # Peer strings MUST be bounded and control-escaped before terminal rendering.
  # Unknown-key wording MUST NOT claim to identify an account or its key count.
  @spec unknown(binary()) :: binary()
  def unknown(fingerprint),
    do:
      dgettext("onboarding", "We don't recognize this SSH key:\n  ") <> safe(fingerprint) <> "\n"

  @spec approval(binary(), binary()) :: binary()
  def approval(fingerprint, url) do
    unknown(fingerprint) <>
      dgettext(
        "onboarding",
        "\nOpen this link, sign in, and approve the matching fingerprint:\n  "
      ) <>
      safe(url) <>
      dgettext("onboarding", "\n\nKeep this SSH connection open while approving the key.\n") <>
      dgettext(
        "onboarding",
        "Approval links expire after %{minutes} minutes or when this connection closes.\n",
        minutes: div(approval_ttl_seconds(), 60)
      ) <>
      dgettext("onboarding", "After approval, retry your command here.\n")
  end

  @spec retry_interactively(binary(), binary() | nil) :: binary()
  def retry_interactively(fingerprint, origin) do
    command =
      if public_origin?(origin),
        do: "\n  ssh " <> URI.parse(origin).host <> "\n",
        else: "\n"

    unknown(fingerprint) <>
      dgettext("onboarding", "\nOpen an interactive Porsche connection without a remote command:") <>
      command <>
      dgettext(
        "onboarding",
        "Keep that connection open while approving your key in the browser,\n"
      ) <>
      dgettext("onboarding", "then retry your original command.\n")
  end

  @spec guidance(diagnosis(), binary(), binary() | nil, :direct | :proxy) :: binary()
  def guidance(diagnosis, fingerprint, origin, mode) do
    heading =
      if mode == :direct,
        do:
          dgettext(
            "onboarding",
            "Welcome to Overalls.\n\nThis connection needs the Overalls SSH configuration.\n\n"
          ),
        else: ""

    reason =
      case diagnosis do
        :unknown ->
          unknown(fingerprint) <> "\n"

        :unavailable ->
          dgettext(
            "onboarding",
            "We couldn't verify this SSH key right now. Please try again shortly.\n\n"
          )

        :denied ->
          dgettext(
            "onboarding",
            "This SSH connection could not be authorized. Check your machine access and try again.\n\n"
          )

        :recognized ->
          ""
      end

    steps =
      if public_origin?(origin) do
        dgettext("onboarding", "Register or check your key by connecting to:\n  ssh ") <>
          URI.parse(origin).host <>
          dgettext("onboarding", "\nOr manage your keys at:\n  ") <>
          origin <> "/settings#ssh-keys\n\n"
      else
        dgettext(
          "onboarding",
          "Register or check your SSH key in Overalls Account settings > SSH keys.\n\n"
        )
      end

    heading <>
      reason <>
      steps <>
      dgettext(
        "onboarding",
        "Follow the browser approval instructions, then run the setup command\n"
      ) <>
      dgettext("onboarding", "from your machine's page and reconnect without root@.\n")
  end

  # @cc [owner:ghuntley,label:protocol] porsche-human-terminal-lines
  # PTY text MUST normalize newlines to CRLF without doubling carriage returns.
  # Non-PTY streams MUST preserve every original byte, including invalid UTF-8.
  @spec terminal_lines(binary(), boolean()) :: binary()
  def terminal_lines(bytes, false), do: bytes

  def terminal_lines(bytes, true) do
    bytes
    |> :binary.replace("\r\n", "\n", [:global])
    |> :binary.replace("\n", "\r\n", [:global])
  end

  @spec safe(binary()) :: binary()
  def safe(value) do
    if byte_size(value) <= 2048 and String.valid?(value) do
      String.replace(
        value,
        ~r/[\x{0000}-\x{001f}\x{007f}-\x{009f}\x{2028}\x{2029}]/u,
        fn <<point::utf8>> ->
          "\\u" <> String.pad_leading(Integer.to_string(point, 16), 4, "0")
        end
      )
    else
      "[invalid value]"
    end
  end
end
