defmodule Marshall.Operations.GitHubConfigTest do
  use ExUnit.Case, async: true
  alias Marshall.Operations.GitHubConfig

  @spec settings() :: %{String.t() => String.t()}
  defp settings do
    %{
      "MARSHALL_GITHUB_CLIENT_ID" => "Iv1.public-client",
      "MARSHALL_GITHUB_CLIENT_SECRET_FILE" => "/run/credentials/marshall/github-client-secret",
      "MARSHALL_GITHUB_REDIRECT_URI" => "https://marshall.example.test/auth/github-com/callback"
    }
  end

  test "absent configuration disables GitHub; configured secrets remain file references" do
    assert GitHubConfig.from_env(%{}) == {:ok, nil}
    assert {:ok, config} = GitHubConfig.from_env(settings())
    assert config[:github_client_secret_file] == settings()["MARSHALL_GITHUB_CLIENT_SECRET_FILE"]
    refute Keyword.has_key?(config, :github_client_secret)

    for key <- Map.keys(settings()) do
      assert GitHubConfig.from_env(Map.delete(settings(), key)) ==
               {:error, :invalid_github_configuration}
    end
  end

  test "production callbacks reject plaintext, credentials, query and alternate paths" do
    for callback <- [
          "http://marshall.example.test/auth/github-com/callback",
          "http://127.0.0.1/auth/github-com/callback",
          "https://credential@example.test/auth/github-com/callback",
          "https://example.test/auth/github-com/callback?state=secret",
          "https://example.test/auth/github-com/callback#secret",
          "https://example.test/auth/github-com/callback/other",
          "https://example.test/auth/github-com/../callback",
          "//example.test/auth/github-com/callback",
          "not-a-url"
        ] do
      assert GitHubConfig.from_env(Map.put(settings(), "MARSHALL_GITHUB_REDIRECT_URI", callback)) ==
               {:error, :invalid_github_configuration}
    end
  end

  test "plaintext development exception is loopback only and explicitly enabled" do
    for host <- ["localhost", "127.0.0.1", "[::1]"] do
      env = Map.put(settings(), "MARSHALL_GITHUB_REDIRECT_URI", "http://#{host}:4123/auth/github-com/callback")
      assert {:ok, _} = GitHubConfig.from_env(env, allow_loopback: true)
      assert {:error, :invalid_github_configuration} = GitHubConfig.from_env(env)
    end

    env = Map.put(settings(), "MARSHALL_GITHUB_REDIRECT_URI", "http://other.test/auth/github-com/callback")
    assert {:error, :invalid_github_configuration} = GitHubConfig.from_env(env, allow_loopback: true)
  end
end
