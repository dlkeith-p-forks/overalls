defmodule OverallsProtocol.SSHHostCertificateTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.SSHHostCertificate, as: Certificate

  @spec keypair() :: {binary(), binary()}
  defp keypair do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {"ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>), seed}
  end

  property "issued host identities verify only at the signed principal, key, CA and interval" do
    check all(offset <- integer(1..1_000_000), serial <- integer(0..1_000_000), max_runs: 50) do
      {ca, seed} = keypair()
      {key, _} = keypair()
      {other, _} = keypair()

      {:ok, line} =
        Certificate.issue(
          key,
          ca,
          seed,
          ["vm.example.test"],
          serial,
          "test",
          offset,
          offset + 100
        )

      assert {:ok, cert} = Certificate.verify(line, ca, key, "vm.example.test", offset)
      assert cert.serial == serial

      for {issuer, leaf, name, now} <- [
            {other, key, "vm.example.test", offset},
            {ca, other, "vm.example.test", offset},
            {ca, key, "other.example.test", offset},
            {ca, key, "vm.example.test", offset - 1},
            {ca, key, "vm.example.test", offset + 100}
          ] do
        assert {:error, :invalid_certificate} = Certificate.verify(line, issuer, leaf, name, now)
      end

      length = byte_size(cert.blob) - 1
      <<prefix::binary-size(^length), last>> = cert.blob

      tampered =
        Certificate.algorithm() <> " " <> Base.encode64(prefix <> <<Bitwise.bxor(last, 1)>>)

      assert {:error, :invalid_certificate} =
               Certificate.verify(tampered, ca, key, "vm.example.test", offset)
    end
  end

  property "arbitrary input never escapes the closed parser" do
    check all(bytes <- binary(max_length: 20_000)) do
      assert match?({:error, :invalid_certificate}, Certificate.parse(bytes))
    end
  end

  test "user key parsing still refuses host certificates and principals cannot broaden trust" do
    {ca, seed} = keypair()
    {key, _} = keypair()

    for names <- [
          [],
          ["*.example.test"],
          ["example.test\nother"],
          ["-bad.example"],
          ["example..test"]
        ] do
      assert {:error, :invalid_certificate} =
               Certificate.issue(key, ca, seed, names, 1, "test", 1, 2)
    end

    {:ok, certificate} = Certificate.issue(key, ca, seed, ["vm.example"], 1, "test", 1, 2)
    assert {:error, :invalid_public_key} = OverallsProtocol.SSHKey.parse(certificate)
    assert {:ok, principal} = Certificate.gateway_principal(key, "ghuntley.dev")
    assert String.ends_with?(principal, ".ssh.ghuntley.dev")
    assert Certificate.hostname?(principal)
  end
end
