defmodule Marshall.NewsletterPropertyTest do
  # @cc [owner:ghuntley,label:security;product] newsletter-subscription-api
  # invalid mailboxes, successful responses and Ghost/transport failures preserve safe outcomes
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Newsletter

  property "only bounded valid mailboxes can reach the subscription boundary", test_cases: 100 do
    value = draw("email", one_of([string(:printable, max_length: 300), binary(max_length: 300)]))

    if Marshall.Accounts.EmailAddress.valid?(value) do
      assert Marshall.Accounts.EmailAddress.valid?(value)
    else
      requester = fn _, _, _ -> flunk("invalid mailbox reached the request boundary") end
      assert Newsletter.subscribe(value, requester) == {:error, :invalid_email}
    end
  end

  property "successful Ghost responses produce a success without exposing request data",
    test_cases: 100 do
    local = draw("local", string(:alphanumeric, min_length: 1, max_length: 24))
    email = local <> "@example.test"
    token = "token-" <> Integer.to_string(draw("token_id", integer(1..10_000)))
    status = draw("signup_status", integer(200..299))
    calls = Overalls.HegelFixtures.start_supervised!({Agent, fn -> [] end})

    assert Newsletter.subscribe(email, successful_requester(calls, token, status)) == :ok

    [
      {:get, "https://ghuntley.com/members/api/integrity-token/", get_options},
      {:post, "https://ghuntley.com/members/api/send-magic-link/", post_options}
    ] = Agent.get(calls, &Enum.reverse/1)

    assert get_options == [receive_timeout: 5_000]
    assert post_options[:receive_timeout] == 5_000
    assert post_options[:json] == %{email: email, emailType: "signup", integrityToken: token}
  end

  property "Ghost and transport failures collapse to the safe unavailable result",
    test_cases: 100 do
    local = draw("local", string(:alphanumeric, min_length: 1, max_length: 24))
    email = local <> "@example.test"
    failure = draw("failure", member_of([:token_http, :signup_http, :transport]))

    requester = fn method, _url, _options ->
      case {failure, method} do
        {:token_http, :get} -> {:ok, %{status: 429, body: "refused"}}
        {:signup_http, :get} -> {:ok, %{status: 200, body: "token"}}
        {:signup_http, :post} -> {:ok, %{status: 400, body: "synthetic upstream detail"}}
        {:transport, _} -> {:error, :timeout}
      end
    end

    assert Newsletter.subscribe(email, requester) == {:error, :unavailable}
  end

  @spec successful_requester(pid(), String.t(), 200..299) :: Newsletter.requester()
  defp successful_requester(calls, token, status) do
    fn method, url, options ->
      Agent.update(calls, &[{method, url, options} | &1])

      case method do
        :get -> {:ok, %{status: 200, body: " \n" <> token <> "\t"}}
        :post -> {:ok, %{status: status}}
      end
    end
  end
end
