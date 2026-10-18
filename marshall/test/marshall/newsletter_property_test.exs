defmodule Marshall.NewsletterPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "only bounded valid mailboxes can reach the subscription boundary", test_cases: 100 do
    value = draw("email", one_of([string(:printable, max_length: 300), binary(max_length: 300)]))

    if Marshall.Accounts.EmailAddress.valid?(value) do
      assert Marshall.Accounts.EmailAddress.valid?(value)
    else
      assert Marshall.Newsletter.subscribe(value) == {:error, :invalid_email}
    end
  end

  property "successful Ghost responses produce a success without exposing request data",
    test_cases: 100 do
    local = draw("local", string(:alphanumeric, min_length: 1, max_length: 24))
    email = local <> "@example.test"
    token = "token-" <> Integer.to_string(draw("token_id", integer(1..10_000)))
    {:ok, calls} = Agent.start_link(fn -> [] end)
    Hegel.on_cleanup(fn -> Agent.stop(calls) end)

    requester = fn method, url, options ->
      Agent.update(calls, &[{method, url, options} | &1])

      case method do
        :get -> {:ok, %{status: 200, body: token}}
        :post -> {:ok, %{status: 204}}
      end
    end

    assert Marshall.Newsletter.subscribe(email, requester) == :ok
    [{:post, _, post_options}, {:get, _, _}] = Agent.get(calls, &Enum.reverse/1)
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
        {:signup_http, :post} -> {:ok, %{status: 400, body: "secret upstream detail"}}
        {:transport, _} -> {:error, :timeout}
      end
    end

    assert Marshall.Newsletter.subscribe(email, requester) == {:error, :unavailable}
  end
end
