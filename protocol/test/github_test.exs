defmodule OverallsProtocol.GitHubTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.{GitHub, Integration}

  @id "01234567-89ab-4def-8123-456789abcdef"
  @other "11234567-89ab-4def-8123-456789abcdef"

  property "closed provider routes round-trip without guest-selected origins" do
    {kind, prefix, method, origin} =
      draw(
        "route",
        member_of([
          {:api, "/api", "POST", "https://api.github.com"},
          {:uploads, "/uploads", "POST", "https://uploads.github.com"},
          {:git, "/git", "POST", "https://github.com"},
          {:gist, "/gist", "GET", "https://gist.github.com"},
          {:raw, "/raw", "GET", "https://raw.githubusercontent.com"},
          {:gist_raw, "/gist-raw", "HEAD", "https://gist.githubusercontent.com"}
        ])
      )

    number = draw("page", integer(1..10_000))
    query = "page=#{number}"

    assert {:ok,
            %{kind: ^kind, method: ^method, path: "/owner/repository", query: ^query} = route} =
             GitHub.request(method, prefix <> "/owner/repository", query)

    assert {:ok, ^route} = route |> GitHub.encode_route() |> GitHub.route()
    assert GitHub.origin(kind) == origin

    assert {:error, :invalid_route} =
             route |> GitHub.encode_route() |> Map.put("target", origin) |> GitHub.route()
  end

  property "path traversal, URL targets, identity fields and credential queries refuse" do
    mutation =
      draw(
        "mutation",
        member_of([
          {"path", "https://attacker.invalid/path"},
          {"path", "//attacker.invalid/path"},
          {"path", "/%2e%2e/secret"},
          {"path", "/ok/%2E/secret"},
          {"path", "/ok%5csecret"},
          {"path", "/ok%0d%0aheader"},
          {"path", "/ok%00secret"},
          {"path", "/broken%"},
          {"path", "/query?url=evil"},
          {"path", "/fragment#x"},
          {"query", "access_token=secret"},
          {"query", "p=1&%73ig=secret"},
          {"query", "X-Amz-Signature=secret"},
          {"query", "jwt=secret"},
          {"query", nil},
          {"method", "CONNECT"},
          {"method", "TRACE"},
          {"method", "get"},
          {"kind", "https://attacker.invalid"},
          {"owner_id", @other},
          {"vm_id", @other}
        ])
      )

    {key, value} = mutation
    assert {:error, :invalid_route} = GitHub.route(Map.put(route(), key, value))
  end

  property "signed downloads accept only the reviewed HTTPS storage names" do
    host =
      draw(
        "host",
        member_of([
          "objects.githubusercontent.com",
          "release-assets.githubusercontent.com",
          "github-releases.githubusercontent.com",
          "github-cloud.githubusercontent.com",
          "github-cloud.s3.amazonaws.com",
          "productionresultssa42.blob.core.windows.net"
        ])
      )

    url = "https://" <> host <> "/object?sig=synthetic-signature"
    assert {:ok, %URI{host: ^host}} = GitHub.download_url(url)
    assert GitHub.credential_url?(url)

    for invalid <- [
          String.replace_prefix(url, "https:", "http:"),
          "https://" <> host <> ".attacker.invalid/object",
          "https://guest@" <> host <> "/object",
          "https://" <> host <> ":8443/object",
          url <> "#fragment"
        ] do
      assert {:error, :invalid_download} = GitHub.download_url(invalid)
    end
  end

  test "capability methods are limited and selectors are exact" do
    selector = String.duplicate("a", 43)

    for method <- ~w(GET HEAD PUT POST) do
      assert {:ok, %{kind: :capability}} =
               GitHub.request(method, "/capabilities/" <> selector, "")
    end

    for {method, path, query} <- [
          {"DELETE", "/capabilities/" <> selector, ""},
          {"GET", "/capabilities//" <> selector, ""},
          {"GET", "/capabilities/" <> selector, "x=1"},
          {"GET", "/capabilities/short", ""}
        ] do
      assert {:error, :invalid_route} = GitHub.request(method, path, query)
    end
  end

  test "authorization carries exactly one fixed provider and a closed lease" do
    lease = %{"kind" => "connected", "id" => @id, "connection_id" => @other, "generation" => 2}

    wire = %{
      "target" => "https://api.github.com",
      "strip_prefix" => nil,
      "headers" => [["authorization", "Bearer synthetic"]],
      "ttl" => 2000,
      "lease" => lease
    }

    assert {:ok, %{lease: decoded}} = GitHub.authorization(wire)
    assert GitHub.encode_lease(decoded) == lease

    for invalid <- [
          Map.put(wire, "extra", true),
          Map.put(wire, "target", "https://attacker.invalid"),
          Map.put(wire, "strip_prefix", "/api"),
          Map.put(wire, "headers", [["host", "attacker.invalid"]]),
          Map.put(wire, "lease", Map.put(lease, "owner_id", @id)),
          Map.put(wire, "lease", Map.put(lease, "generation", 0)),
          Map.put(wire, "lease", Map.put(lease, "generation", 9_223_372_036_854_775_808))
        ] do
      assert {:error, :invalid_authorization} = GitHub.authorization(invalid)
    end

    assert {:ok, :anonymous} = GitHub.lease(%{"kind" => "anonymous"})
  end

  test "guest credentials and transport headers disappear while CLI metadata survives" do
    assert GitHub.request_headers([
             {"authorization", "Bearer guest"},
             {"cookie", "guest=1"},
             {"proxy-authorization", "Basic guest"},
             {"x-overalls-binding", "forged"},
             {"host", "evil"},
             {"accept", "application/vnd.github+json"},
             {"git-protocol", "version=2"},
             {"range", "bytes=0-99"},
             {"user-agent", "gh 2.80"},
             {"content-type", "bad\r\nheader"}
           ]) == [
             {"accept", "application/vnd.github+json"},
             {"git-protocol", "version=2"},
             {"range", "bytes=0-99"},
             {"user-agent", "gh 2.80"}
           ]

    assert GitHub.response_headers([
             {"set-cookie", "provider=1"},
             {"www-authenticate", "Bearer secret"},
             {"link", "<https://api.github.com/repos/o/r?page=2>; rel=\"next\""},
             {"etag", "\"tag\""},
             {"x-ratelimit-remaining", "20"}
           ]) == [
             {"link", "<https://api.github.com/repos/o/r?page=2>; rel=\"next\""},
             {"etag", "\"tag\""},
             {"x-ratelimit-remaining", "20"}
           ]
  end

  test "built-in name is unavailable to generic integration configuration" do
    refute Integration.name?(GitHub.name())
    assert {:error, :invalid_hostname} = Integration.label(GitHub.hostname())
    assert GitHub.integration_type() == "github-com"

    assert {:ok, "https://com-github.integration.internal/api/repos/o/r?page=2"} =
             GitHub.internal_url("https://api.github.com/repos/o/r?page=2")

    assert {:error, :invalid_download} = GitHub.transfer_url("https://github.com/login")
    assert {:ok, _} = GitHub.transfer_url("https://github.com/o/r.git/info/lfs/verify")
  end

  @spec route() :: map()
  defp route,
    do: %{"kind" => "api", "method" => "GET", "path" => "/repos/owner/repository", "query" => ""}
end
