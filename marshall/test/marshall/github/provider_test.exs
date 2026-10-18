defmodule Marshall.GitHub.ProviderTest do
  use ExUnit.Case, async: true
  alias Marshall.GitHub.{Grant, Provider}

  test "realistic OAuth token responses omit offline_access and normalize parent scopes" do
    assert {:ok, grant} =
             Grant.decode(%{
               "access_token" => "synthetic-access",
               "refresh_token" => "synthetic-refresh",
               "expires_in" => 28_800,
               "refresh_token_expires_in" => 15_897_600,
               "scope" => "repo,workflow,read:org,project,gist,notifications,user,write:packages"
             })

    refute "offline_access" in grant.scopes
    assert Provider.sufficient_scopes?(grant.scopes)
    refute Provider.sufficient_scopes?(grant.scopes -- ["repo"])
    refute Provider.sufficient_scopes?(grant.scopes -- ["workflow"])
  end

  test "malformed or nonexpiring token pairs are refused" do
    for body <- [
          %{},
          %{"access_token" => "a", "scope" => "repo"},
          %{
            "access_token" => "a",
            "refresh_token" => "r",
            "expires_in" => 0,
            "refresh_token_expires_in" => 10,
            "scope" => "repo"
          }
        ] do
      assert {:error, :invalid_response} = Grant.decode(body)
    end
  end
end
