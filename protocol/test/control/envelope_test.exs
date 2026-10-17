defmodule OverallsProtocol.Control.EnvelopeTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen

  alias OverallsProtocol.Control.{Close, Envelope}

  @alphanumeric_chars Enum.concat([?a..?z, ?A..?Z, ?0..?9])

  @spec uuid(<<_::128>>) :: String.t()
  defp uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end

  @spec name() :: :hegel_gen.t(String.t())
  defp name,
    do: map(list(member_of(Enum.to_list(?a..?z)), min: 1, max: 20), &List.to_string/1)

  @spec message() :: :hegel_gen.t(Envelope.message())
  defp message do
    id = integer(0..1_000_000)

    key =
      map(list(member_of(@alphanumeric_chars), min: 0, max: 8), &List.to_string/1)

    body = map_of(key, integer(), max: 3)

    one_of([
      map(tuple([name(), body]), fn {service, bind} ->
        {:hello, %{version: 1, service: service, bind: bind}}
      end),
      map(tuple([id, name(), body]), fn {i, op, b} -> {:req, %{id: i, op: op, body: b}} end),
      map(tuple([id, body]), fn {i, b} -> {:res, %{id: i, result: {:ok, b}}} end),
      map(tuple([id, name()]), fn {i, e} -> {:res, %{id: i, result: {:error, e}}} end),
      map(tuple([name(), binary(16, 16)]), fn {kind, bytes} ->
        {:hint, %{kind: kind, id: uuid(bytes)}}
      end),
      constant(:resync),
      map(id, &{:ping, &1}),
      map(id, &{:pong, &1})
    ])
  end

  property "every message round-trips",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 20_261_108 do
    message = draw("message", message())
    assert Envelope.decode(Envelope.encode(message)) == {:ok, message}
  end

  property "arbitrary JSON never raises",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 20_261_109 do
    text = draw("text", utf8(0, 200))

    assert match?({:ok, _}, Envelope.decode(text)) or
             Envelope.decode(text) in [
               {:error, :invalid_message},
               {:error, :unsupported_version}
             ]
  end

  test "versions, extra fields and bad names are refused" do
    assert Envelope.decode(~s({"k":"hello","v":2,"service":"lilly","bind":{}})) ==
             {:error, :unsupported_version}

    assert Envelope.decode(~s({"k":"req","id":1,"op":"Op!","body":{}})) ==
             {:error, :invalid_message}

    assert Envelope.decode(~s({"k":"req","id":-1,"op":"op","body":{}})) ==
             {:error, :invalid_message}

    assert Envelope.decode(~s({"k":"resync","x":1})) == {:error, :invalid_message}
    assert Envelope.decode(~s({"k":"hint","kind":"user","id":"x"})) == {:error, :invalid_message}
  end

  test "every close reason maps to one code and reaction" do
    for reason <- [
          :refused,
          :unsupported_version,
          :fenced,
          :superseded,
          :overloaded,
          :protocol_violation,
          :reauthenticate,
          :draining,
          :idle
        ] do
      assert Close.reason(Close.code(reason)) == reason

      assert Close.reaction(reason) in [
               :stop,
               :fence,
               :reconnect,
               :reconnect_now,
               :reload_credential
             ]
    end

    assert Close.reason(1006) == :lost
    assert Close.reason(nil) == :lost
    assert Close.reaction(:unsupported_version) == :stop
    assert Close.reaction(:draining) == :reconnect_now
  end
end
