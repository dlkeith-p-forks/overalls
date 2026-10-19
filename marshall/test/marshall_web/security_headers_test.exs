defmodule MarshallWeb.SecurityHeadersTest do
  use MarshallWeb.ConnCase, async: true

  alias MarshallWeb.SecurityHeaders

  @csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; " <>
         "base-uri 'self'; form-action 'self' https://ghuntley.com https://github.com; frame-ancestors 'self'; frame-src 'self'; " <>
         "worker-src 'self'; manifest-src 'self'"

  @permissions "accelerometer=(), autoplay=(), camera=(), clipboard-read=(self), " <>
                 "clipboard-write=(self), " <>
                 "display-capture=(), geolocation=(), gyroscope=(), hid=(), idle-detection=(), " <>
                 "local-fonts=(), magnetometer=(), microphone=(), midi=(), payment=(), " <>
                 "picture-in-picture=(), screen-wake-lock=(), serial=(), usb=(), " <>
                 "xr-spatial-tracking=()"

  @expected [
    {"content-security-policy", @csp},
    {"permissions-policy", @permissions},
    {"cross-origin-opener-policy", "same-origin"},
    {"cross-origin-resource-policy", "same-origin"},
    {"referrer-policy", "strict-origin-when-cross-origin"},
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "SAMEORIGIN"},
    {"x-permitted-cross-domain-policies", "none"}
  ]

  # @cc [owner:ghuntley,label:security;verification] security-headers-on-every-surface
  # Browser pages, redirects, static files, health probes, refused /api paths and
  # JSON API replies MUST all carry exactly one copy of each security header.
  test "every response surface carries the fixed header set once" do
    responses = [
      {"browser page", get(build_conn(), "https://localhost/sign-in"), 200},
      {"redirect", get(build_conn(), "https://localhost/"), 302},
      {"static file", get(build_conn(), "https://localhost/robots.txt"), 200},
      {"health", get(build_conn(), "https://localhost/health/live"), 200},
      {"api refusal", get(build_conn(), "https://localhost/api/fleet/v1/identity"), 404},
      {"json api",
       build_conn()
       |> put_req_header("accept", "application/json")
       |> get("https://localhost/api/agents/v1/session"), 400}
    ]

    for {surface, response, status} <- responses do
      assert response.status == status, surface

      for {name, value} <- @expected do
        assert get_resp_header(response, name) == [value], "#{surface}: #{name}"
      end
    end

    assert get_resp_header(Enum.at(responses, 5) |> elem(1), "content-type") |> hd() =~
             "application/json"
  end

  test "the test environment compiles the production policy" do
    refute SecurityHeaders.development_tooling?()
    assert SecurityHeaders.policy(false) == @csp

    assert List.keyfind(SecurityHeaders.headers(), "content-security-policy", 0) ==
             {"content-security-policy", @csp}
  end

  test "development tooling relaxes only script, style, connect, frame and image sources" do
    development = SecurityHeaders.policy(true)
    assert development =~ "script-src 'self' 'unsafe-inline' 'unsafe-eval' http://localhost:*;"
    assert development =~ "connect-src 'self' http://localhost:* ws://localhost:*;"
    assert development =~ "style-src 'self' 'unsafe-inline' http://localhost:*;"
    assert development =~ "frame-src 'self' http://localhost:*;"
    assert development =~ "img-src 'self' data: http://localhost:*;"
    assert development =~ "default-src 'self'; "
    assert development =~ "object-src 'none'; "

    assert development =~
             "form-action 'self' https://ghuntley.com https://github.com; frame-ancestors 'self'; "

    refute "https:" in String.split(development, [" ", ";"], trim: true)
  end

  test "the production policy never allows inline or evaluated script" do
    [script] =
      SecurityHeaders.policy(false)
      |> String.split("; ")
      |> Enum.filter(&String.starts_with?(&1, "script-src "))

    assert script == "script-src 'self'"
  end

  test "form redirects admit GitHub OAuth only alongside the fixed newsletter origin" do
    [forms] =
      SecurityHeaders.policy(false)
      |> String.split("; ")
      |> Enum.filter(&String.starts_with?(&1, "form-action "))

    assert String.split(forms) == [
             "form-action",
             "'self'",
             "https://ghuntley.com",
             "https://github.com"
           ]
  end

  test "a route may tighten a header without duplicating it" do
    response =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> get("https://localhost/machines/#{Ash.UUID.generate()}/code")

    assert response.status == 302
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(response, "content-security-policy") == [@csp]
  end
end
