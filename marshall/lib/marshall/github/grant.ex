defmodule Marshall.GitHub.Grant do
  @moduledoc false
  @enforce_keys [:access_token, :refresh_token, :expires_in, :refresh_expires_in, :scopes]
  @derive {Inspect, only: [:expires_in, :refresh_expires_in, :scopes]}
  defstruct [:access_token, :refresh_token, :expires_in, :refresh_expires_in, :scopes]

  @type t :: %__MODULE__{
          access_token: binary(),
          refresh_token: binary(),
          expires_in: pos_integer(),
          refresh_expires_in: pos_integer(),
          scopes: [binary()]
        }

  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_response}
  def decode(%{
        "access_token" => access,
        "refresh_token" => refresh,
        "expires_in" => expiry,
        "refresh_token_expires_in" => refresh_expiry,
        "scope" => scopes
      })
      when is_binary(access) and byte_size(access) in 1..4096 and
             is_binary(refresh) and byte_size(refresh) in 1..4096 and
             is_integer(expiry) and expiry in 1..86_400 and
             is_integer(refresh_expiry) and refresh_expiry in 1..31_622_400 and
             is_binary(scopes) and byte_size(scopes) <= 4096 do
    parsed = String.split(scopes, [",", " "], trim: true) |> Enum.uniq() |> Enum.sort()

    {:ok,
     %__MODULE__{
       access_token: access,
       refresh_token: refresh,
       expires_in: expiry,
       refresh_expires_in: refresh_expiry,
       scopes: parsed
     }}
  end

  def decode(_), do: {:error, :invalid_response}

  @spec encode(t()) :: %{required(String.t()) => String.t() | pos_integer()}
  def encode(%__MODULE__{} = grant) do
    %{
      "access_token" => grant.access_token,
      "refresh_token" => grant.refresh_token,
      "expires_in" => grant.expires_in,
      "refresh_token_expires_in" => grant.refresh_expires_in,
      "scope" => Enum.join(grant.scopes, ",")
    }
  end
end
