defmodule Lilly.Host.InceptionProofTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.InceptionProof

  test "native receipt binds every input and rejects invented eligibility flags" do
    boot = "11111111-1111-4111-8111-111111111111"
    image = "sha256:" <> String.duplicate("a", 64)
    probe = "/nix/store/current-native-probe"
    firecracker = "/nix/store/current-vmm/bin/firecracker"

    receipt = %{
      "version" => 1,
      "boot_id" => boot,
      "image_id" => image,
      "probe_id" => probe,
      "firecracker" => firecracker
    }

    assert InceptionProof.matches?(receipt, boot, image, probe, firecracker)

    for key <- Map.keys(receipt) do
      refute InceptionProof.matches?(Map.delete(receipt, key), boot, image, probe, firecracker)

      refute InceptionProof.matches?(
               Map.put(receipt, key, "changed"),
               boot,
               image,
               probe,
               firecracker
             )
    end

    refute InceptionProof.matches?(
             Map.put(receipt, "version", 1.0),
             boot,
             image,
             probe,
             firecracker
           )

    refute InceptionProof.matches?(
             Map.put(receipt, "nested", true),
             boot,
             image,
             probe,
             firecracker
           )

    refute InceptionProof.matches?(%{"svm" => true}, boot, image, probe, firecracker)
    assert InceptionProof.image_id(nil) == nil
  end
end
