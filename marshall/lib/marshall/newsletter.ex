defmodule Marshall.Newsletter do
  @moduledoc "Server-side Ghost newsletter subscription client."
  alias Marshall.Accounts.EmailAddress

  @type result :: :ok | {:error, :invalid_email | :unavailable}
  @token_url "https://ghuntley.com/members/api/integrity-token/"
  @signup_url "https://ghuntley.com/members/api/send-magic-link/"

  # @cc [owner:ghuntley,label:security;product] newsletter-request-boundary
  # Subscription MUST validate the bounded mailbox before any request, use only
  # the fixed Ghost endpoints, and collapse all upstream failures to :unavailable.
  @spec subscribe(term()) :: result()
  def subscribe(email) when is_binary(email) do
    if EmailAddress.valid?(email), do: request(email), else: {:error, :invalid_email}
  end

  def subscribe(_), do: {:error, :invalid_email}

  defp request(email) do
    with {:ok, %{status: 200, body: token}} <- Req.get(@token_url, receive_timeout: 5_000),
         token when is_binary(token) <- String.trim(token),
         {:ok, %{status: status}} when status in 200..299 <-
           Req.post(@signup_url,
             json: %{email: email, emailType: "signup", integrityToken: token},
             receive_timeout: 5_000
           ) do
      :ok
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
