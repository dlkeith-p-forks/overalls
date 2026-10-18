defmodule Marshall.Newsletter do
  @moduledoc "Server-side Ghost newsletter subscription client."
  alias Marshall.Accounts.EmailAddress

  @type result :: :ok | {:error, :invalid_email | :unavailable}
  @token_url "https://ghuntley.com/members/api/integrity-token/"
  @signup_url "https://ghuntley.com/members/api/send-magic-link/"

  # @cc [owner:ghuntley,label:security;product] newsletter-request-boundary
  # Subscription MUST validate the bounded mailbox before any request, use only
  # the fixed Ghost endpoints, and collapse all upstream failures to :unavailable.
  @type requester :: (atom(), String.t(), keyword() -> {:ok, map()} | {:error, term()})

  @spec subscribe(term(), requester()) :: result()
  def subscribe(email, requester \\ &request/3) when is_binary(email) do
    if EmailAddress.valid?(email), do: request(email, requester), else: {:error, :invalid_email}
  end

  def subscribe(_, _requester), do: {:error, :invalid_email}

  defp request(email, requester) do
    with {:ok, %{status: 200, body: token}} <-
           requester.(:get, @token_url, receive_timeout: 5_000),
         token when is_binary(token) <- String.trim(token),
         {:ok, %{status: status}} when status in 200..299 <-
           requester.(:post, @signup_url,
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

  @spec request(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp request(:get, url, opts), do: Req.get(url, opts)
  defp request(:post, url, opts), do: Req.post(url, opts)
end
