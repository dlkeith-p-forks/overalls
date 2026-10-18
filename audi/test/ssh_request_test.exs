defmodule Audi.SSH.RequestTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.SSH.Request

  property "every accepted command is a bounded label or fixed nested selector" do
    bytes = draw("bytes", binary(max_length: 1000))

    case Request.parse(bytes) do
      {:ok, label} when is_binary(label) ->
        assert bytes == "connect " <> label
        assert byte_size(label) <= 63
        assert OverallsProtocol.IngressName.valid_label?(label)

      {:ok, {:nested, label, service}} ->
        assert service in [:porsche_ssh, :audi_ssh]
        assert {:ok, ^label, ^service} = OverallsProtocol.InceptionName.ssh_selector(bytes)

      :error ->
        :ok
    end
  end

  test "nested selectors reject shell syntax, arbitrary services and whitespace variants" do
    assert Request.parse("inception vm-11111111111141118111111111111111 porsche") ==
             {:ok, {:nested, "vm-11111111111141118111111111111111", :porsche_ssh}}

    assert Request.parse("inception vm-11111111111141118111111111111111 audi") ==
             {:ok, {:nested, "vm-11111111111141118111111111111111", :audi_ssh}}

    for command <- [
          "inception vm-11111111111141118111111111111111 22",
          "inception vm-11111111111141118111111111111111 audi;id",
          "inception  vm-11111111111141118111111111111111 audi",
          "inception vm-11111111111141118111111111111111 audi ",
          "inception 127.0.0.1 audi",
          "inception vm-11111111111141118111111111111111 https"
        ] do
      assert Request.parse(command) == :error
    end
  end

  test "SSH grants require this host, the selected VM label, port 22 and complete identity" do
    id = "11111111-1111-4111-8111-111111111111"
    label = "vm-11111111111141118111111111111111"

    binding = %{
      host_id: id,
      vm_id: id,
      placement_id: id,
      session_id: id,
      execution_epoch: 1,
      generation: 1,
      service: :ssh,
      port: 22,
      label: label
    }

    grant = %{binding: binding, ticket: :test, ttl: 5000}
    assert Request.grant?(grant, label, id)

    for field <- Map.keys(binding) do
      refute Request.grant?(%{grant | binding: Map.delete(binding, field)}, label, id)
    end

    refute Request.grant?(%{grant | ttl: 30_001}, label, id)
    refute Request.grant?(%{grant | binding: %{binding | port: 80}}, label, id)
    refute Request.grant?(grant, "other", id)
    refute Request.grant?(grant, label, "22222222-2222-4222-8222-222222222222")

    {:ok, key} = OverallsProtocol.SSHKey.from_blob(<<11::32, "ssh-ed25519", 32::32, 0::256>>)
    nested = %{binding | service: :audi_ssh} |> Map.put(:environment_generation, 1)
    grant = %{grant | binding: nested} |> Map.put(:host_key, key.public_key)
    selector = {:nested, label, :audi_ssh}
    assert Request.grant?(grant, selector, id)

    for field <- Map.keys(nested) do
      refute Request.grant?(%{grant | binding: Map.delete(nested, field)}, selector, id)
    end

    refute Request.grant?(Map.delete(grant, :host_key), selector, id)
    refute Request.grant?(%{grant | host_key: key.public_key <> " comment"}, selector, id)
    refute Request.grant?(grant, {:nested, label, :porsche_ssh}, id)
    refute Request.grant?(grant, selector, "22222222-2222-4222-8222-222222222222")
    refute Request.grant?(grant, label, id)
  end
end
