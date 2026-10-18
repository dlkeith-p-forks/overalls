defmodule Audi.HTTP.EditorAssetsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import Plug.Conn
  alias Audi.HTTP.EditorAssets
  @moduletag :tmp_dir
  @hash "1" <> String.duplicate("v", 51)
  @release String.duplicate("b", 64)
  @relative "out/vs/workbench/contrib/webview/browser/pre"

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, @relative))

    for filename <- ["index.html", "fake.html", "service-worker.js"] do
      path = Path.join([root, @relative, filename])
      File.write!(path, filename)
      File.chmod!(path, 0o444)
    end

    %{
      assets: %{
        root: root,
        descriptor: %{protocol: 1, commit: String.duplicate("a", 40), release: @release}
      }
    }
  end

  test "fixed assets are served without authority cookies or a guest connector", c do
    for filename <- ["index.html", "fake.html", "service-worker.js"], method <- [:get, :head] do
      response =
        Plug.Test.conn(
          method,
          "https://#{@hash}.apps.test/code-assets/#{@release}/#{@relative}/#{filename}"
        )
        |> put_req_header("cookie", "private-canary")
        |> EditorAssets.call(editor_assets: c.assets, zone: "apps.test")

      assert response.status == 200
      assert get_resp_header(response, "set-cookie") == []
      assert get_resp_header(response, "cache-control") == ["public, max-age=31536000, immutable"]
      refute response.resp_body =~ "private-canary"
      refute_received {:guest_binding, _}
    end

    assert {:error, :invalid_editor_assets} = EditorAssets.load(c.assets.root)
  end

  property "untrusted paths never select a file outside the three release assets", c do
    fragment = draw("fragment", string(:alphanumeric, min_length: 1, max_length: 40))

    for path <- [
          fragment,
          "../#{fragment}",
          "index.html/#{fragment}",
          "index.html%2f#{fragment}",
          "index.html/../fake.html"
        ] do
      response =
        Plug.Test.conn(
          :get,
          "https://#{@hash}.apps.test/code-assets/#{@release}/#{@relative}/#{path}"
        )
        |> EditorAssets.call(editor_assets: c.assets, zone: "apps.test")

      assert response.status == 404
    end
  end

  test "release, origin, symlink and method mismatches refuse before file serving", c do
    correct = "https://#{@hash}.apps.test/code-assets/#{@release}/#{@relative}/index.html"

    for url <- [
          String.replace(correct, @release, String.duplicate("c", 64)),
          String.replace(correct, @hash, "foreign"),
          String.replace(correct, "apps.test", "foreign.test")
        ],
        do:
          assert(
            EditorAssets.call(Plug.Test.conn(:get, url),
              editor_assets: c.assets,
              zone: "apps.test"
            ).status == 404
          )

    assert EditorAssets.call(Plug.Test.conn(:post, correct),
             editor_assets: c.assets,
             zone: "apps.test"
           ).status == 404

    path = Path.join([c.assets.root, @relative, "index.html"])
    File.rm!(path)
    File.ln_s!(Path.join(c.assets.root, "outside"), path)

    assert EditorAssets.call(Plug.Test.conn(:get, correct),
             editor_assets: c.assets,
             zone: "apps.test"
           ).status == 404
  end
end
