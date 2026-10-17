defmodule NativeIsolationFixture do
  @moduledoc false
  alias Lilly.Network.{Config, Guest, Policy}

  # @cc [owner:ghuntley,label:verification;security] native-isolation-real-policy
  # Fixture rules MUST come from the packaged Lilly policy with validated
  # operator and guest identities. Test code MUST NOT substitute permissive
  # forwarding or source guards for the production programs.
  @spec prepare() :: :ok
  def prepare do
    host = "11111111-1111-4111-8111-111111111111"

    {:ok, config} =
      Config.new(host, "uplink", ["8.8.4.5/32"], "/run/native-isolation", true, true)

    {:ok, guest} = Guest.new(host, :standard, 203)
    File.mkdir_p!("/run/native-isolation")
    File.write!("/run/native-isolation/policy.nft", Policy.router(config) <> Policy.guard(guest))

    File.write!(
      "/run/native-isolation/identity.json",
      JSON.encode!(%{
        namespace: config.namespace,
        tap: guest.tap,
        guard: guest.guard,
        address: guest.address,
        gateway: guest.gateway,
        mac: guest.mac,
        ingress_mark: Policy.ingress_mark(:ssh)
      })
    )
  end
end

NativeIsolationFixture.prepare()
