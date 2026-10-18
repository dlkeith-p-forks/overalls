defmodule OverallsProtocol.GitIdentity do
  @moduledoc "Closed Git attribution metadata; never authentication or execution authority."
  @type t :: %{name: String.t(), email: String.t()}
  @type failure :: {:error, :invalid_message}

  # @cc [owner:ghuntley,label:security;protocol] git-identity-bounded-attribution
  # Identities MUST contain exactly a trimmed, nonempty UTF-8 name of at most
  # 128 bytes and an ASCII mailbox of at most 254 bytes. Names MUST NOT contain
  # controls or angle brackets; mailboxes MUST NOT contain whitespace, controls
  # or display-name delimiters. Validation MUST preserve attribution verbatim.
  @spec validate(term()) :: {:ok, t()} | failure()
  def validate(%{name: name, email: email} = value) when map_size(value) == 2 do
    if name?(name) and email?(email), do: {:ok, value}, else: {:error, :invalid_message}
  end

  def validate(_), do: {:error, :invalid_message}

  @spec valid?(term()) :: boolean()
  def valid?(value), do: match?({:ok, _}, validate(value))

  # @cc [owner:ghuntley,label:protocol] git-identity-closed-version
  # Wire identities MUST contain exactly version 1, name and email; unknown
  # versions and added fields MUST fail closed without creating peer atoms.
  @spec decode(term()) :: {:ok, t()} | failure()
  def decode(%{"version" => 1, "name" => name, "email" => email} = value)
      when map_size(value) == 3,
      do: validate(%{name: name, email: email})

  def decode(_), do: {:error, :invalid_message}

  @spec encode(t()) :: map()
  def encode(%{name: name, email: email}), do: %{"version" => 1, "name" => name, "email" => email}

  @spec name?(term()) :: boolean()
  defp name?(value) when is_binary(value) and byte_size(value) in 1..128 do
    String.valid?(value) and String.trim(value) == value and
      not Regex.match?(~r/[\p{Cc}\p{Cf}<>]/u, value)
  end

  defp name?(_), do: false

  @spec email?(term()) :: boolean()
  defp email?(value) when is_binary(value) and byte_size(value) in 3..254,
    do:
      Regex.match?(
        ~r/\A[A-Za-z0-9!\#$%&'*+\-\/=?^_`{|}~]+(?:\.[A-Za-z0-9!\#$%&'*+\-\/=?^_`{|}~]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\z/,
        value
      )

  defp email?(_), do: false
end
