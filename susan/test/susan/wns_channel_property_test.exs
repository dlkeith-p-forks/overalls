defmodule Susan.WNSChannelPropertyTest do
  # The susan-wns-channel-shape contract in lib/susan/provider.ex.
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Susan.Provider

  test "accepts the documented channel shape and refuses near misses" do
    assert Provider.wns_channel?("https://wns2-par02p.notify.windows.com/w/?token=AwYAAAB")
    assert Provider.wns_channel?("https://bn3p.notify.windows.com/?token=x")

    for uri <- [
          "http://wns2-par02p.notify.windows.com/w/?token=x",
          "https://notify.windows.com/w/?token=x",
          "https://evil.example/notify.windows.com/x",
          "https://wns.notify.windows.com.evil.example/w",
          "https://wns.notify.windows.com:8443/w",
          "https://user@wns.notify.windows.com/w",
          "https://wns.notify.windows.com/w#frag",
          "https://WNS.notify.windows.com/w",
          "https://wns.notify.windows.com",
          "https://wns.notify.windows.com/w\\..",
          "https://wns.notify.windows.com/" <> String.duplicate("a", 1024),
          nil,
          42
        ] do
      refute Provider.wns_channel?(uri), inspect(uri)
    end
  end

  @tag :hegel
  test "an accepted channel always posts to a notify.windows.com host on 443" do
    Hegel.check(
      fn ->
        scheme = draw("scheme", member_of(["https", "http", "HTTPS", "ftp"]))
        prefix = draw("prefix", string(:alphanumeric, min_length: 1, max_length: 20))

        suffix =
          draw(
            "suffix",
            member_of([".notify.windows.com", ".windows.com", ".notify.windows.com.example", ""])
          )

        port = draw("port", member_of(["", ":443", ":444", ":80"]))
        userinfo = draw("userinfo", member_of(["", "u@", "u:p@"]))
        path = draw("path", string(:printable, max_length: 80))

        uri =
          scheme <> "://" <> userinfo <> String.downcase(prefix) <> suffix <> port <> "/" <> path

        if Provider.wns_channel?(uri) do
          parsed = URI.parse(uri)
          assert parsed.scheme == "https" and parsed.port == 443 and parsed.userinfo == nil
          assert String.ends_with?(parsed.host, ".notify.windows.com")
          assert Provider.allowed_url?(uri)
        end
      end,
      test_cases: 300
    )
  end
end
