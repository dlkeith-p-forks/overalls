defmodule Marshall.Accounts.GitUsername do
  @moduledoc "Bounded Git author names without control characters or identity delimiters."
  use Ash.Type

  @impl true
  @spec storage_type(keyword()) :: :string
  def storage_type(_), do: :string
  @impl true
  @spec cast_input(term(), keyword()) :: {:ok, String.t()} | :error
  def cast_input(value, _) when is_binary(value) do
    if valid?(value), do: {:ok, value}, else: :error
  end

  def cast_input(_, _), do: :error
  @impl true
  @spec cast_stored(term(), keyword()) :: {:ok, String.t()} | :error
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  @spec dump_to_native(term(), keyword()) :: {:ok, String.t()} | :error
  def dump_to_native(value, constraints), do: cast_input(value, constraints)

  # @cc [owner:ghuntley,label:security] git-name-single-identity
  # Names MUST be trimmed nonempty UTF-8, at most 128 bytes, and contain no control
  # or Unicode format characters or angle brackets; malformed external data MUST be rejected.
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    byte_size(value) in 1..128 and String.valid?(value) and String.trim(value) == value and
      not Regex.match?(~r/[\p{Cc}\p{Cf}<>]/u, value)
  end

  def valid?(_), do: false
end
