# Runtime-only synthetic devices; never print push keys, private keys or bodies.
defmodule PushRelayProbe do
  @moduledoc false
  alias Marshall.{Notifications, SSH}
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.{Delivery, DeliveryWorker, Device}
  alias OverallsProtocol.PushPoke

  @root "/run/push-fixture"
  @route "/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12"
  @deployment "control.example.test"

  @type result :: %{required(String.t()) => term()}

  @spec run() :: :ok
  def run do
    oban = Application.fetch_env!(:marshall, Oban)
    Application.put_env(:marshall, Oban, Keyword.put(oban, :testing, :manual))
    {:ok, _} = Application.ensure_all_started(:marshall)
    result = @root |> Path.join("action") |> File.read!() |> String.trim() |> act()
    File.write!(Path.join(@root, "result.json"), Jason.encode!(result))
    :ok
  end

  # Registers a device with the push key the real Susan issued and delivers
  # one needs-input poke through Susan to the fake provider.
  @spec act(String.t()) :: result()
  defp act("deliver") do
    owner = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "relay-owner@example.test"})
    push_key = @root |> Path.join("push-key") |> File.read!() |> String.trim()
    {device, private} = register!(owner, push_key)
    File.write!(Path.join(@root, "device"), device.id)
    File.write!(Path.join(@root, "private"), Base.url_encode64(private, padding: false))
    delivery = enqueue!(device, "needs_input:first")
    _ = drain()
    [row] = Ledger.read!(Delivery, id: delivery.id)

    %{
      "delivery" => delivery.id,
      "state" => Atom.to_string(row.state),
      "attempts" => row.attempts
    }
  end

  defp act("gone") do
    [device] = Ledger.read!(Device, id: File.read!(Path.join(@root, "device")))
    gone = enqueue!(device, "needs_input:gone")
    _ = drain()
    later = enqueue!(device, "needs_input:later")
    _ = drain()
    [device] = Ledger.read!(Device, id: device.id)
    [gone] = Ledger.read!(Delivery, id: gone.id)
    [later] = Ledger.read!(Delivery, id: later.id)

    %{
      "device_state" => Atom.to_string(device.state),
      "device_reason" => device.state_reason && Atom.to_string(device.state_reason),
      "gone" => Atom.to_string(gone.state),
      "later" => [Atom.to_string(later.state), Atom.to_string(later.drop_reason)]
    }
  end

  # Opens every APNs body the fake provider received with the device key: the
  # relay forwarded ciphertext only, and only this device can read it.
  defp act("open") do
    private = @root |> Path.join("private") |> File.read!() |> Base.url_decode64!(padding: false)
    {_, stranger} = PushPoke.generate_key_pair()

    opened =
      @root
      |> Path.join("provider.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["host"] == "api.push.apple.com"))
      |> Enum.map(fn %{"body" => body} ->
        %{"overalls" => %{"c" => ciphertext}} = Jason.decode!(body)
        {:ok, poke} = PushPoke.open(ciphertext, private, @deployment)

        %{
          "opens" => poke.route == @route and poke.kind == :needs_input,
          "stranger" => PushPoke.open(ciphertext, stranger, @deployment) == {:error, :authentication},
          "content_free" => not String.contains?(body, ["threads", "7a1c0e44", "relay-owner"])
        }
      end)

    %{"opened" => opened}
  end

  @spec register!(Ash.Resource.record(), String.t()) :: {Ash.Resource.record(), binary()}
  defp register!(owner, push_key) do
    raw = :crypto.strong_rand_bytes(32)
    blob = <<11::32, "ssh-ed25519", 32::32, raw::binary>>
    {:ok, key} = SSH.add_key(%{public_key: "ssh-ed25519 " <> Base.encode64(blob)}, actor: owner)
    {public, private} = PushPoke.generate_key_pair()

    {:ok, view} =
      Notifications.register_device(
        %{
          platform: :ios,
          push_key: push_key,
          enc_public_key: Base.url_encode64(public, padding: false),
          key_id: key.id
        },
        actor: owner
      )

    [device] = Ledger.read!(Device, id: view.id)
    {device, private}
  end

  defp enqueue!(device, collapse_key) do
    delivery =
      Ledger.create!(Delivery, :enqueue, %{
        device_id: device.id,
        user_id: device.user_id,
        kind: :needs_input,
        collapse_key: collapse_key,
        route: @route,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    %{delivery_id: delivery.id} |> DeliveryWorker.new() |> Oban.insert!()
    delivery
  end

  defp drain do
    Oban.drain_queue(queue: :notifications, with_scheduled: true, with_recursion: true)
  end
end

PushRelayProbe.run()
