defmodule OverallsProtocol.WebStreamTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.WebStream
  @vm "00000000-0000-4000-8000-000000000001"
  @host "00000000-0000-4000-8000-000000000002"
  @label "app-00000000000040008000000000000001"

  property "unknown caller authority and invalid app selectors are rejected",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_608_428_795 do
    port = draw("port", integer(3000..9999))
    extra = draw("extra", member_of(["host_id", "port", "user_id", "address"]))
    request = %{"version" => 1, "label" => @label, "app_port" => port, "cookie" => nil}
    assert {:ok, :open_web, _} = WebStream.request("web-open", request)

    assert {:error, :invalid_message} =
             WebStream.request("web-open", Map.put(request, extra, @host))

    assert {:error, :invalid_message} =
             WebStream.request("web-open", %{request | "app_port" => port + 10000})
  end

  property "renewal cannot change any execution or user binding",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_915_664_515 do
    epoch = draw("epoch", integer(1..1_000_000))
    port = draw("port", integer(1..65535))
    ttl = draw("ttl", integer(1..30000))

    binding = %{
      "vm_id" => @vm,
      "host_id" => @host,
      "placement_id" => @vm,
      "session_id" => @host,
      "execution_epoch" => epoch,
      "generation" => 1,
      "label" => @label,
      "service" => "web",
      "port" => port
    }

    ticket =
      "audi_web_stream_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    grant = %{"binding" => binding, "user_id" => nil, "ttl" => ttl, "ticket" => ticket}

    assert {:ok, opened} =
             WebStream.response("web-open", %{"version" => 1, "grant" => grant}, @host, @label)

    renewed = Map.delete(grant, "ticket")

    assert {:ok, _} =
             WebStream.response(
               "web-renew",
               %{"version" => 1, "grant" => renewed},
               @host,
               @label,
               opened
             )

    changed = put_in(renewed, ["binding", "execution_epoch"], epoch + 1)

    assert {:error, _} =
             WebStream.response(
               "web-renew",
               %{"version" => 1, "grant" => changed},
               @host,
               @label,
               opened
             )

    assert {:error, _} =
             WebStream.response(
               "web-renew",
               %{"version" => 1, "grant" => Map.put(renewed, "user_id", @vm)},
               @host,
               @label,
               opened
             )
  end

  property "arbitrary peer terms do not escape the decoder",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 403_630_710 do
    value = draw("value", OverallsProtocol.TestGenerators.peer_term())

    assert match?({:error, :invalid_message}, WebStream.request("web-open", value)) or
             is_map(value)

    assert match?(
             {:error, :invalid_message},
             WebStream.response("web-open", value, @host, @label)
           ) or is_map(value)
  end
end
