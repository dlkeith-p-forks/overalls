defmodule MarshallWeb.ArtifactContentHeaders do
  @moduledoc """
  The lockdown header set of the artifact content origin. One function owns
  every header so pages, files, refusals and 404s are identical.
  """
  import Plug.Conn

  @permissions_policy Enum.join(
                        [
                          "accelerometer=()",
                          "autoplay=()",
                          "bluetooth=()",
                          "camera=()",
                          "clipboard-read=()",
                          "clipboard-write=()",
                          "display-capture=()",
                          "fullscreen=()",
                          "geolocation=()",
                          "gyroscope=()",
                          "hid=()",
                          "magnetometer=()",
                          "microphone=()",
                          "midi=()",
                          "payment=()",
                          "publickey-credentials-get=()",
                          "screen-wake-lock=()",
                          "serial=()",
                          "usb=()",
                          "xr-spatial-tracking=()"
                        ],
                        ", "
                      )

  # @cc [owner:ghuntley,label:security] artifact-content-lockdown-headers
  # Every content-origin response MUST carry exactly this header set, replacing
  # any earlier value: a CSP whose `sandbox allow-scripts` gives the document an
  # opaque origin (no cookies, storage, forms, popups, top navigation or
  # downloads), no network or worker access, framing only by Marshall's origin,
  # COOP/COEP/CORP isolation, a deny-all permissions policy, nosniff,
  # no-referrer, private no-store caching and HSTS without subdomains. It never
  # sets a cookie.
  @spec headers(String.t(), String.t()) :: [{String.t(), String.t()}]
  def headers(content_host, marshall_host)
      when is_binary(content_host) and is_binary(marshall_host) do
    origin = "https://" <> content_host

    [
      {"content-security-policy",
       Enum.join(
         [
           "sandbox allow-scripts",
           "default-src 'none'",
           "script-src 'unsafe-inline' " <> origin,
           "style-src 'unsafe-inline' " <> origin,
           "img-src data: blob: " <> origin,
           "font-src " <> origin,
           "media-src " <> origin,
           "connect-src 'none'",
           "worker-src 'none'",
           "manifest-src 'none'",
           "frame-src 'none'",
           "child-src 'none'",
           "object-src 'none'",
           "form-action 'none'",
           "base-uri 'none'",
           "frame-ancestors https://" <> marshall_host
         ],
         "; "
       )},
      {"cross-origin-opener-policy", "same-origin"},
      {"cross-origin-resource-policy", "same-site"},
      {"cross-origin-embedder-policy", "require-corp"},
      {"permissions-policy", @permissions_policy},
      {"x-content-type-options", "nosniff"},
      {"referrer-policy", "no-referrer"},
      {"cache-control", "private, no-store"},
      {"strict-transport-security", "max-age=63072000"}
    ]
  end

  @spec put(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def put(conn, content_host, marshall_host) do
    # The test-only echo probe deliberately emits a cookie for the proxy to strip.
    conn =
      if conn.private[:artifact_echo_probe],
        do: conn,
        else: delete_resp_header(conn, "set-cookie")

    Enum.reduce(headers(content_host, marshall_host), conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end
end
