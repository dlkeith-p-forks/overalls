defmodule OverallsProtocol.IntegrationTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.Integration

  @alphanumeric_chars Enum.concat([48..57, 65..90, 97..122])

  property "names accept only closed lowercase labels",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_313_659_727 do
    name = draw("name", alphanumeric_string(1, 40))
    letter_start = name =~ ~r/\A[a-z]/
    lowercase = name == String.downcase(name)

    case Integration.name?(name) do
      true ->
        assert letter_start and lowercase
        composed = name <> ".integration.internal"
        assert {:ok, ^composed} = Integration.hostname(name)

      false ->
        assert not letter_start or not lowercase or name in ["ssh", "com-github"]
    end
  end

  property "hostnames with multiple labels, uppercase or off-zone never address an integration",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 921_798_668 do
    prefix = draw("prefix", member_of([".", "A.", "a.b.", "-.", "a-."]))
    suffix = draw("suffix", member_of(["", ".attacker.com", ".integration.internal.evil.com"]))
    value = prefix <> "esample.integration.internal" <> suffix
    assert {:error, :invalid_hostname} = Integration.label(value)
  end

  test "valid labels round-trip through hostname composition" do
    assert {:ok, "esample"} = Integration.label("esample.integration.internal")
    assert {:ok, "a"} = Integration.label("a.integration.internal")
    assert {:ok, "mirror-1"} = Integration.label("mirror-1.integration.internal")
    assert {:error, :invalid_hostname} = Integration.label("llm.internal")
    assert {:error, :invalid_hostname} = Integration.label("integration.internal")
    assert {:error, :invalid_hostname} = Integration.label("esample.integration.internal.")
    assert {:error, :invalid_name} = Integration.hostname("Esample")
    assert {:error, :invalid_name} = Integration.hostname("ssh")
    assert {:error, :invalid_hostname} = Integration.label("ssh.integration.internal")
  end

  property "targets must be fixed https origins without paths, users or queries",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 646_038_397 do
    host = draw("host", alphanumeric_string(1, 32))
    path = draw("path", member_of(["", "/", "/x", "?q=1"]))
    scheme = draw("scheme", member_of(["https", "http"]))
    value = scheme <> "://" <> host <> ".example.test" <> path

    case Integration.target(value) do
      {:ok, ^value} -> assert scheme == "https" and path == ""
      {:error, :invalid_target} -> assert scheme == "http" or path != ""
    end
  end

  property "strip prefixes are absolute segment-aligned paths",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_428_207_923 do
    segments =
      draw(
        "segments",
        list(alphanumeric_string(1, 8), min: 1, max: 8)
      )

    path = "/" <> Enum.join(segments, "/")

    assert {:ok, ^path} = Integration.strip_prefix(path)
    assert {:error, :invalid_strip_prefix} = Integration.strip_prefix(path <> "//x")
  end

  test "strip prefix boundaries" do
    assert {:ok, nil} = Integration.strip_prefix(nil)
    assert {:ok, "/api/v3"} = Integration.strip_prefix("/api/v3")
    assert {:ok, "/api/v3/"} = Integration.strip_prefix("/api/v3/")
    assert {:error, :invalid_strip_prefix} = Integration.strip_prefix("api/v3")
    assert {:error, :invalid_strip_prefix} = Integration.strip_prefix("/")
    assert {:error, :invalid_strip_prefix} = Integration.strip_prefix("/api v3")
    assert {:error, :invalid_strip_prefix} = Integration.strip_prefix("/api;drop")
  end

  property "header injection rejects transport impersonation and line smuggling",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 799_585_711 do
    name =
      draw(
        "name",
        member_of([
          "host",
          "transfer-encoding",
          "x-overalls-binding",
          "x-overalls-source-vm",
          "x-forwarded-for"
        ])
      )

    value = draw("value", utf8(1, 64))
    assert {:error, :invalid_header} = Integration.header([name, value])
    assert {:error, :invalid_header} = Integration.static_header([name, value])
  end

  property "header values cannot smuggle CR, LF or NUL",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_648_097_373 do
    value = draw("value", utf8(1, 64))
    smuggled = value <> "\r\nX-Smuggled: 1"

    assert {:error, :invalid_header} = Integration.header(["x-custom"])
    assert {:error, :invalid_header} = Integration.header(["x-custom", smuggled])
    assert {:error, :invalid_header} = Integration.header(["x-custom", value <> "\0"])
  end

  test "bounded valid headers are accepted and authorization stays platform-computed" do
    assert {:ok, {"x-api-token", "sk-123"}} = Integration.header(["x-api-token", "sk-123"])

    assert {:ok, {"Prettiest-Of-Them-All", "me"}} =
             Integration.header(["Prettiest-Of-Them-All", "me"])

    assert {:ok, {"authorization", "Bearer sk-test"}} =
             Integration.header(["authorization", "Bearer sk-test"])

    assert {:error, :invalid_header} =
             Integration.static_header(["authorization", "Bearer sk-test"])

    assert {:error, :invalid_header} = Integration.header(["x-a", ""])
    assert {:error, :invalid_header} = Integration.header(["x a", "v"])
  end

  test "bearer and basic credentials validate their computed authorization values" do
    assert {:ok, "token-value"} = Integration.bearer_credential("token-value")
    assert {:ok, "alice:hunter2"} = Integration.basic_credential("alice:hunter2")

    for invalid <- [nil, "", "-", "token\r\nsmuggled"] do
      assert {:error, :invalid_credential} = Integration.bearer_credential(invalid)
    end

    for invalid <- [nil, "", "-", "missing-colon", ":password", "alice:bad\nvalue"] do
      assert {:error, :invalid_credential} = Integration.basic_credential(invalid)
    end
  end

  test "authorization responses stay closed" do
    valid = %{
      "target" => "https://api.example.test",
      "strip_prefix" => nil,
      "headers" => [["authorization", "Bearer sk-test"]],
      "ttl" => 2000
    }

    assert {:ok,
            %{
              target: "https://api.example.test",
              strip_prefix: nil,
              headers: [{"authorization", "Bearer sk-test"}],
              peer: nil,
              ttl: 2000
            }} =
             Integration.authorization(valid)

    assert {:error, :invalid_authorization} =
             Integration.authorization(Map.put(valid, "extra", true))

    assert {:error, :invalid_authorization} =
             Integration.authorization(Map.put(valid, "target", "http://api.example.test"))

    assert {:error, :invalid_authorization} =
             Integration.authorization(Map.put(valid, "headers", [["host", "evil.test"]]))

    assert {:error, :invalid_authorization} =
             Integration.authorization(Map.put(valid, "peer", %{"endpoint" => "https://a.test"}))

    peer =
      Map.put(valid, "peer", %{
        "endpoint" => "https://bob.example.test",
        "token" => "galileo_peer_" <> String.duplicate("a", 43)
      })

    assert {:ok, %{peer: %{endpoint: "https://bob.example.test", token: token}}} =
             Integration.authorization(peer)

    assert byte_size(token) == 56
  end

  test "renewal responses contain only a bounded relative lease" do
    assert {:ok, %{ttl: 2000}} = Integration.renewal(%{"version" => 1, "ttl" => 2000})

    for invalid <- [
          %{"version" => 1, "ttl" => 499},
          %{"version" => 1, "ttl" => 5001},
          %{"version" => 2, "ttl" => 2000},
          %{"version" => 1, "ttl" => 2000, "target" => "https://api.example.test"}
        ] do
      assert {:error, :invalid_renewal} = Integration.renewal(invalid)
    end
  end

  property "peer attestations bind exactly source, name and bounded expiry",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 2_020_729_568 do
    expires = draw("expires", integer(-100_000..0))

    assert {:error, :invalid_attestation} =
             Integration.peer_attestation(attestation(expires))
  end

  test "valid peer attestation" do
    id = "01234567-89ab-4def-8123-456789abcdef"

    assert {:ok, %{source_vm_id: ^id, name: "esample", expires_at: 4}} =
             Integration.peer_attestation(attestation(4))

    extra = Map.put(attestation(4), "target", "https://evil.test")
    assert {:error, :invalid_attestation} = Integration.peer_attestation(extra)
  end

  test "peer-open envelopes bind opaque provenance to one destination grant" do
    token = "galileo_peer_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    label = "app-0123456789ab4def8123456789abcdef"

    request = %{"version" => 1, "peer_token" => token, "label" => label, "app_port" => 0}
    assert {:ok, %{peer_token: ^token, label: ^label}} = Integration.peer_open_request(request)

    for invalid <- [
          %{request | "version" => 2},
          Map.put(request, "extra", true),
          %{request | "app_port" => 3000},
          %{request | "peer_token" => "galileo_peer_" <> String.duplicate("a", 43)}
        ] do
      assert {:error, :invalid_peer_open} = Integration.peer_open_request(invalid)
    end

    response = %{
      "version" => 1,
      "attestation" => attestation(4),
      "grant" => peer_grant(label)
    }

    assert {:ok, %{attestation: %{name: "esample"}, grant: %{binding: %{label: ^label}}}} =
             Integration.peer_open_response(
               response,
               "11234567-89ab-4def-8123-456789abcdef",
               label
             )

    assert {:error, :invalid_peer_open} =
             Integration.peer_open_response(
               Map.put(response, "extra", true),
               "11234567-89ab-4def-8123-456789abcdef",
               label
             )
  end

  defp peer_grant(label) do
    %{
      "ttl" => 5000,
      "user_id" => nil,
      "ticket" =>
        "audi_web_stream_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      "binding" => %{
        "vm_id" => "01234567-89ab-4def-8123-456789abcdef",
        "host_id" => "11234567-89ab-4def-8123-456789abcdef",
        "placement_id" => "21234567-89ab-4def-8123-456789abcdef",
        "session_id" => "31234567-89ab-4def-8123-456789abcdef",
        "execution_epoch" => 1,
        "generation" => 1,
        "label" => label,
        "service" => "web",
        "port" => 8080
      }
    }
  end

  defp attestation(expires) do
    %{
      "purpose" => "galileo-peer",
      "source_vm_id" => "01234567-89ab-4def-8123-456789abcdef",
      "name" => "esample",
      "expires_at" => expires
    }
  end

  @spec alphanumeric_string(pos_integer(), pos_integer()) :: :hegel_gen.t(String.t())
  defp alphanumeric_string(min, max) do
    map(list(member_of(@alphanumeric_chars), min: min, max: max), &List.to_string/1)
  end
end
