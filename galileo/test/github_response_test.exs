defmodule Galileo.GitHub.ResponseTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Galileo.GitHub.{Capabilities, Response}
  alias OverallsProtocol.GitHub

  @id "01234567-89ab-4def-8123-456789abcdef"
  @url "https://release-assets.githubusercontent.com/object?sig=synthetic"
  @oid String.duplicate("a", 64)

  setup do
    server = start_supervised!({Capabilities, name: nil})

    context = %{
      binding: %{"host_id" => @id, "vm_id" => @id, "placement_id" => @id, "execution_epoch" => 1},
      lease: :anonymous,
      capabilities: server
    }

    {:ok, context: context}
  end

  test "redirects, pagination and nested signed URLs reveal only internal selectors", %{
    context: context
  } do
    assert {:ok, headers} =
             Response.headers(
               [
                 {"set-cookie", "secret"},
                 {"www-authenticate", "Bearer secret"},
                 {"location", @url},
                 {"link", "<https://api.github.com/repos/o/r?page=2>; rel=\"next\""},
                 {"x-ratelimit-remaining", "21"}
               ],
               context
             )

    refute List.keymember?(headers, "set-cookie", 0)
    refute List.keymember?(headers, "www-authenticate", 0)
    assert {"location", location} = List.keyfind(headers, "location", 0)
    assert location =~ "https://com-github.integration.internal/capabilities/"
    refute location =~ "sig="

    assert {"link",
            "<https://com-github.integration.internal/api/repos/o/r?page=2>; rel=\"next\""} in headers

    assert {:ok, bytes} =
             Response.json(Jason.encode!(%{"nested" => [%{"download" => @url}]}), context)

    refute bytes =~ "synthetic"
    refute bytes =~ "release-assets"
    assert %{"nested" => [%{"download" => nested_location}]} = Jason.decode!(bytes)
    assert nested_location =~ "https://com-github.integration.internal/capabilities/"
    assert {:ok, bytes} = Response.json(Jason.encode!(%{"count" => 3, "ok" => true}), context)
    assert Jason.decode!(bytes) == %{"count" => 3, "ok" => true}
  end

  property "malformed links and unreviewed signed URLs refuse before bytes", %{context: context} do
    value =
      draw(
        "invalid",
        member_of([
          "https://attacker.invalid/file?sig=secret",
          "https://api.github.com/repos/o/r?access_token=secret",
          "https://guest:secret@api.github.com/repos/o/r"
        ])
      )

    assert {:error, :invalid_response} = Response.headers([{"location", value}], context)
    assert {:error, :invalid_response} = Response.headers([{"link", value}], context)

    assert {:error, :invalid_response} =
             Response.headers(
               [{"link", "<https://api.github.com/repos/o/r>; rel=\"next\"\r\nsecret"}],
               context
             )
  end

  test "unknown signed JSON locations and invalid JSON fail closed", %{context: context} do
    assert {:error, :invalid_response} =
             Response.json(
               Jason.encode!(%{
                 "archive_download_url" => "https://unknown.invalid/object?sig=synthetic"
               }),
               context
             )

    assert {:error, :invalid_response} = Response.json("not-json", context)
  end

  test "LFS upload, download and verify credentials stay in method-bound selectors", %{
    context: context
  } do
    context =
      Map.put(context, :route, %{
        kind: :git,
        method: "POST",
        path: "/o/r.git/info/lfs/objects/batch",
        query: ""
      })

    actions = %{
      "download" => %{
        "href" => @url,
        "header" => %{"Authorization" => "RemoteAuth download-secret"}
      },
      "upload" => %{
        "href" => "https://github-cloud.s3.amazonaws.com/object?X-Amz-Signature=upload-secret",
        "header" => %{"Content-Type" => "application/octet-stream"}
      },
      "verify" => %{
        "href" => "https://github.com/o/r.git/info/lfs/verify",
        "header" => %{"Authorization" => "RemoteAuth verify-secret"}
      }
    }

    batch = %{
      "transfer" => "basic",
      "objects" => [%{"oid" => @oid, "size" => 3, "actions" => actions}]
    }

    assert {:ok, bytes} = Response.json(Jason.encode!(batch), context)
    refute bytes =~ "-secret"
    refute bytes =~ "X-Amz-Signature"
    %{"objects" => [%{"actions" => safe}]} = Jason.decode!(bytes)

    for {name, method} <- [{"download", "GET"}, {"upload", "PUT"}, {"verify", "POST"}] do
      assert %{"href" => href, "header" => %{}} = safe[name]
      assert {:ok, route} = GitHub.request(method, URI.parse(href).path, "")

      assert {:ok, transfer} =
               Capabilities.resolve(
                 String.replace_prefix(route.path, "/", ""),
                 context.binding,
                 context.lease,
                 method,
                 context.capabilities
               )

      assert transfer.object == %{oid: @oid, size: 3, repository: "/o/r.git/info/lfs"}
      assert transfer.method == method
      assert transfer.url == actions[name]["href"]

      if method != "GET",
        do:
          assert(
            {:error, :unavailable} ==
              Capabilities.resolve(
                String.replace_prefix(route.path, "/", ""),
                context.binding,
                context.lease,
                method,
                context.capabilities
              )
          )
    end
  end

  test "invalid LFS action fields and credential targets refuse", %{context: context} do
    context =
      Map.put(context, :route, %{
        kind: :git,
        method: "POST",
        path: "/o/r.git/info/lfs/objects/batch",
        query: ""
      })

    for action <- [
          %{
            "href" => "https://attacker.invalid/object",
            "header" => %{"Authorization" => "secret"}
          },
          %{"href" => @url, "header" => %{"Host" => "attacker.invalid"}},
          %{"href" => @url, "expires_in" => 0},
          %{"href" => @url, "extra" => true}
        ] do
      batch = %{"objects" => [%{"oid" => @oid, "size" => 3, "actions" => %{"upload" => action}}]}
      assert {:error, :invalid_response} = Response.json(Jason.encode!(batch), context)
    end
  end
end
