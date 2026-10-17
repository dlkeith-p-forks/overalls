defmodule OverallsProtocol.InceptionNameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.{InceptionName, IngressName}
  @environment IngressName.label("dev", "11111111-1111-4111-8111-111111111111")
  @workload IngressName.label("web", "22222222-2222-4222-8222-222222222222")

  test "public names select the exact environment and fixed listener" do
    assert {:ok, names} = InceptionName.origins(@environment, "apps.example")

    assert {:ok, @environment, :control_https} =
             InceptionName.route(names.control, "apps.example")

    assert {:ok, @environment, :audi_https} =
             InceptionName.route(@workload <> "." <> names.apps, "apps.example")

    assert {:ok, @environment, :audi_https} =
             InceptionName.route("p3000-" <> @workload <> "." <> names.apps, "apps.example")

    assert {:control, 443} = InceptionName.destination(:control_https)
    assert {:audi, 443} = InceptionName.destination(:audi_https)
  end

  test "suffix confusion, recursion, wildcard and arbitrary service names fail" do
    {:ok, names} = InceptionName.origins(@environment, "apps.example")

    for host <- [
          names.control <> ".evil",
          "evil" <> names.control,
          names.apps,
          "*." <> names.apps,
          "ssh." <> names.namespace,
          "p22." <> @workload <> "." <> names.apps,
          "p3000." <> @workload <> "." <> names.apps,
          "control." <> @environment <> ".inception." <> names.apps,
          String.upcase(names.control),
          "control.." <> names.namespace
        ] do
      assert :error = InceptionName.route(host, "apps.example")
    end

    for zone <- [
          "",
          "Apps.example",
          "example.",
          "a..b",
          "-bad.example",
          String.duplicate("a", 64)
        ] do
      assert {:error, :invalid_inception_name} = InceptionName.origins(@environment, zone)
    end

    assert {:error, :invalid_inception_name} =
             InceptionName.origins(
               @environment,
               Enum.join(List.duplicate(String.duplicate("a", 60), 3), ".")
             )
  end

  test "the child wildcard proof owner cannot publish an address" do
    assert InceptionName.wildcard_proof_owner?("apps." <> @environment <> ".inception")
    refute InceptionName.publication?("apps." <> @environment <> ".inception")
    refute InceptionName.wildcard_proof_owner?("apps.bad.inception")
  end

  test "namespace reserves the complete DNS-01 owner, not only the HTTP name" do
    zone = String.duplicate("a", 63) <> "." <> String.duplicate("b", 55)
    workload = "v-" <> String.duplicate("w", 28) <> "-" <> String.duplicate("2", 32)
    assert {:ok, names} = InceptionName.origins(@environment, zone)
    assert byte_size("_acme-challenge." <> workload <> "." <> names.apps) == 253
    assert {:error, :invalid_inception_name} = InceptionName.origins(@environment, zone <> "b")
  end

  test "SSH selectors cannot inject destinations or additional arguments" do
    assert {:ok, @environment, :porsche_ssh} =
             InceptionName.ssh_selector("inception #{@environment} porsche")

    assert {:ok, @environment, :audi_ssh} =
             InceptionName.ssh_selector("inception #{@environment} audi")

    for command <- [
          "inception #{@environment} root@127.0.0.1",
          "inception #{@environment} audi 22",
          "inception #{@environment} audi\n",
          "inception  #{@environment} audi",
          "inception #{@environment} audi;id"
        ] do
      assert :error = InceptionName.ssh_selector(command)
    end
  end

  property "arbitrary names and commands fail without raising" do
    check all(value <- binary(max_length: 512)) do
      assert InceptionName.route(value, "apps.example") == :error
      assert InceptionName.ssh_selector(value) == :error
    end
  end
end
