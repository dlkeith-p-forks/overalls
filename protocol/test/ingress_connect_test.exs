defmodule OverallsProtocol.IngressConnectTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.IngressConnect, as: Wire
  @id "11111111-1111-4111-8111-111111111111"
  defp connector_binding do
    %{
      vm_id: @id,
      host_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      label: OverallsProtocol.IngressName.label("vm", @id),
      service: :ssh,
      port: 22
    }
  end

  property "arbitrary bytes never produce a partial or unvalidated binding" do
    check all(bytes <- binary(max_length: 4096)) do
      case Wire.decode(bytes) do
        {:ok, binding} -> assert Wire.valid?(binding)
        error -> assert error == {:error, :invalid_connector_request}
      end
    end
  end

  property "all bounded execution identities round trip" do
    check all(
            epoch <- integer(1..9_223_372_036_854_775_807),
            generation <- integer(1..9_223_372_036_854_775_807)
          ) do
      value = %{connector_binding() | execution_epoch: epoch, generation: generation}
      assert {:ok, bytes} = Wire.encode(value)
      assert byte_size(bytes) < Wire.maximum()
      assert {:ok, ^value} = Wire.decode(bytes)
    end
  end

  property "web ports preserve exact execution binding and do not widen SSH" do
    check all(port <- integer(1..65535)) do
      value = %{connector_binding() | service: :web, port: port}

      if port == 4444 do
        refute Wire.valid?(value)
        assert {:error, :invalid_connector_request} = Wire.encode(value)
      else
        assert {:ok, bytes} = Wire.encode(value)
        assert {:ok, ^value} = Wire.decode(bytes)
      end

      if port != 22, do: refute(Wire.valid?(%{value | service: :ssh}))
      refute Wire.valid?(Map.put(value, :address, "127.0.0.1"))
      refute Wire.valid?(%{value | service: :tcp})
    end
  end

  test "nested bindings use a distinct closed version with fixed ports and profile" do
    for service <- [:control_https, :porsche_ssh, :audi_https, :audi_ssh] do
      {_, port} = OverallsProtocol.InceptionName.destination(service)

      binding =
        connector_binding()
        |> Map.merge(%{service: service, port: port, environment_generation: 7})

      assert {:ok, bytes} = Wire.encode(binding)
      assert {:ok, ^binding} = Wire.decode(bytes)
      message = JSON.decode!(bytes)
      assert message["version"] == 2
      assert Wire.valid_for_profile?(binding, :inception)

      for profile <- [:customer, :standard, :oss, nil] do
        refute Wire.valid_for_profile?(binding, profile)
      end

      for changed <- [
            Map.put(message, "version", 1),
            put_in(message, ["binding", "port"], port + 1),
            put_in(message, ["binding", "environment_generation"], 0),
            put_in(message, ["binding", "environment_generation"], 9_223_372_036_854_775_807),
            put_in(message, ["binding", "address"], "127.0.0.1"),
            put_in(message, ["binding"], Map.delete(message["binding"], "environment_generation"))
          ] do
        assert {:error, :invalid_connector_request} = Wire.decode(JSON.encode!(changed))
      end
    end
  end

  property "ordinary connector admission preserves Customer isolation" do
    check all(port <- integer(1..65535)) do
      binding = connector_binding()
      assert Wire.valid_for_profile?(binding, :customer)
      web = %{binding | service: :web, port: port}
      refute Wire.valid_for_profile?(web, :customer)
      refute Wire.valid_for_profile?(web, :unknown)

      for profile <- [:standard, :oss, :inception] do
        assert Wire.valid_for_profile?(web, profile) == (port != 4444)
      end
    end
  end

  test "ordinary web admission rejects the dedicated editor port for every profile" do
    value = %{connector_binding() | service: :web, port: 4444}
    refute Wire.valid?(value)
    assert {:error, :invalid_connector_request} = Wire.encode(value)

    for profile <- [:customer, :standard, :oss, :inception] do
      refute Wire.valid_for_profile?(value, profile)
    end

    {:ok, bytes} = Wire.encode(%{value | port: 4443})
    message = JSON.decode!(bytes)

    assert {:error, :invalid_connector_request} =
             Wire.decode(JSON.encode!(put_in(message, ["binding", "port"], 4444)))
  end

  test "closed schema rejects extra/missing fields, alternate services and stale formats" do
    {:ok, bytes} = Wire.encode(connector_binding())
    message = JSON.decode!(bytes)

    for changed <- [
          Map.put(message, "version", 2),
          Map.put(message, "address", "127.0.0.1"),
          put_in(message, ["binding", "port"], 2222),
          put_in(message, ["binding", "service"], "tcp"),
          put_in(message, ["binding", "generation"], 0),
          put_in(message, ["binding", "execution_epoch"], 9_223_372_036_854_775_807),
          put_in(
            message,
            ["binding", "label"],
            OverallsProtocol.IngressName.label("vm", "22222222-2222-4222-8222-222222222222")
          ),
          put_in(message, ["binding"], Map.delete(message["binding"], "session_id"))
        ] do
      assert {:error, :invalid_connector_request} = Wire.decode(JSON.encode!(changed))
    end

    assert {:error, :invalid_connector_request} = Wire.decode(String.duplicate(" ", 2049))
    assert Wire.ready?(Wire.ready())
    refute Wire.ready?(~s({"version":1,"ready":true,"extra":true}))
    refute Wire.ready?(~s({"version":2,"ready":true}))
  end
end
