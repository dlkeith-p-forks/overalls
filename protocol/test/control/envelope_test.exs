defmodule OverallsProtocol.Control.EnvelopeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias OverallsProtocol.Control.{Close, Envelope}

  @spec uuid() :: String.t()
  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end

  @spec name() :: Hegel.Gen.t(String.t())
  defp name, do: map(string(?a..?z, min_length: 1, max_length: 20), & &1)

  @spec message() :: Hegel.Gen.t(Envelope.message())
  defp message do
    id = integer(0..1_000_000)
    body = map_of(string(:alphanumeric, max_length: 8), integer(), max_length: 3)

    one_of([
      map({name(), body}, fn {service, bind} ->
        {:hello, %{version: 1, service: service, bind: bind}}
      end),
      map({id, name(), body}, fn {i, op, b} -> {:req, %{id: i, op: op, body: b}} end),
      map({id, body}, fn {i, b} -> {:res, %{id: i, result: {:ok, b}}} end),
      map({id, name()}, fn {i, e} -> {:res, %{id: i, result: {:error, e}}} end),
      map(name(), fn kind -> {:hint, %{kind: kind, id: uuid()}} end),
      constant(:resync),
      map(id, &{:ping, &1}),
      map(id, &{:pong, &1})
    ])
  end

  property "every message round-trips" do
    check all(message <- message()) do
      assert Envelope.decode(Envelope.encode(message)) == {:ok, message}
    end
  end

  property "arbitrary JSON never raises" do
    check all(text <- string(:printable, max_length: 200)) do
      assert match?({:ok, _}, Envelope.decode(text)) or
               Envelope.decode(text) in [
                 {:error, :invalid_message},
                 {:error, :unsupported_version}
               ]
    end
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
