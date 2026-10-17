defmodule Marshall.Accounts.EmailAddress do
  @moduledoc "Bounded ASCII mailbox addresses without SMTP header or command syntax."
  @pattern ~r/\A[A-Za-z0-9!\#$%&'*+\-\/=?^_`{|}~]+(?:\.[A-Za-z0-9!\#$%&'*+\-\/=?^_`{|}~]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\z/
  use Ash.Type.NewType, subtype_of: :ci_string, constraints: [max_length: 254, match: @pattern]

  # @cc [owner:ghuntley,label:security] email-address-no-command-syntax
  # Validation MUST accept only bounded ASCII mailbox syntax without CR/LF, null,
  # whitespace or display-name delimiters. Nonbinary input MUST return false.
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value),
    do: byte_size(value) in 3..254 and Regex.match?(@pattern, value)

  def valid?(_), do: false
end
