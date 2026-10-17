defmodule OverallsProtocol.WebLoginTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.WebLogin

  property "redemption fields require independent canonical bearer purposes" do
    check all(bytes <- binary(length: 32)) do
      state = Base.url_encode64(bytes, padding: false)

      request = %{
        "version" => 1,
        "ticket" => "audi_web_login_" <> state,
        "code" => "audi_web_code_" <> state,
        "state" => state
      }

      assert {:ok, :exchange_web_login, _} = WebLogin.request("web-login-exchange", request)

      assert {:error, :invalid_request} =
               WebLogin.request("web-login-exchange", %{request | "code" => request["ticket"]})

      assert {:error, :invalid_request} =
               WebLogin.request("web-login-exchange", Map.put(request, "user_id", "forged"))

      assert {:error, :invalid_request} =
               WebLogin.request("web-login-exchange", %{request | "state" => state <> "="})

      for key <- Map.keys(request),
          do:
            assert(
              {:error, :invalid_request} ==
                WebLogin.request("web-login-exchange", Map.delete(request, key))
            )
    end
  end

  test "replies cannot redirect to another host or substitute a code for a cookie" do
    state = Base.url_encode64(<<0::256>>, padding: false)

    value = %{
      "version" => 1,
      "login" => %{
        "hostname" => "vm.example",
        "expires_at" => "2030-01-01T00:00:00Z",
        "cookie" => "audi_web_cookie_" <> state
      }
    }

    assert {:ok, _} = WebLogin.response("web-login-exchange", value, "vm.example")

    assert {:error, :invalid_message} =
             WebLogin.response("web-login-exchange", value, "other.example")

    assert {:error, :invalid_message} =
             WebLogin.response(
               "web-login-exchange",
               put_in(value, ["login", "cookie"], "audi_web_code_" <> state),
               "vm.example"
             )
  end
end
