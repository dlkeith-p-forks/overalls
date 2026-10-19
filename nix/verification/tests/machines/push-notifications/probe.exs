# Runtime-only synthetic devices; never print push keys, private keys or bodies.
defmodule PushNotificationsProbe do
  @moduledoc false
  alias Marshall.{Notifications, SSH}
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.{Delivery, DeliveryWorker, Device}
  alias OverallsProtocol.{PushPoke, SusanPoke}

  @root "/run/push-fixture"
  @route "/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12"

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

  @spec act(String.t()) :: result()
  defp act("deliver") do
    owner = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "push-owner@example.test"})
    {device, private} = register!(owner)
    File.write!(Path.join(@root, "device"), device.id)
    File.write!(Path.join(@root, "private"), Base.url_encode64(private, padding: false))
    delivery = enqueue!(device, "needs_input:first")
    drained = drain()
    [row] = Ledger.read!(Delivery, id: delivery.id)

    %{
      "delivery" => delivery.id,
      "state" => Atom.to_string(row.state),
      "attempts" => row.attempts,
      "drained" => drained,
      "requests" => verify_requests(private, device)
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
      "gone" => [Atom.to_string(gone.state), Atom.to_string(gone.drop_reason)],
      "later" => [Atom.to_string(later.state), Atom.to_string(later.drop_reason)]
    }
  end

  defp act("disabled") do
    owner = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "push-disabled@example.test"})

    refusal =
      case register(owner) do
        {:error, %{errors: [%{reason: reason}]}} -> Atom.to_string(reason)
        {:ok, _} -> "registered"
        {:error, _} -> "other"
      end

    %{"enabled" => Notifications.enabled?(), "refusal" => refusal}
  end

  @spec register!(Ash.Resource.record()) :: {Ash.Resource.record(), binary()}
  defp register!(owner) do
    {{:ok, view}, private} = register_with_private(owner)
    [device] = Ledger.read!(Device, id: view.id)
    {device, private}
  end

  defp register(owner), do: owner |> register_with_private() |> elem(0)

  defp register_with_private(owner) do
    raw = :crypto.strong_rand_bytes(32)
    blob = <<11::32, "ssh-ed25519", 32::32, raw::binary>>
    {:ok, key} = SSH.add_key(%{public_key: "ssh-ed25519 " <> Base.encode64(blob)}, actor: owner)
    {public, private} = PushPoke.generate_key_pair()

    {Notifications.register_device(
       %{
         platform: :ios,
         push_key: Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false),
         enc_public_key: Base.url_encode64(public, padding: false),
         key_id: key.id
       },
       actor: owner
     ), private}
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
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # Every recorded request must verify, decode canonically and open only with
  # the device key; the body must not contain the route or its identifiers.
  defp verify_requests(private, device) do
    @root
    |> Path.join("requests.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      %{"body" => body, "key" => key, "signature" => signature, "status" => status} =
        Jason.decode!(line)

      {:ok, request} = SusanPoke.decode(body)
      {:ok, poke} = PushPoke.open(request.ciphertext, private, request.deployment)
      {_, stranger} = PushPoke.generate_key_pair()

      %{
        "status" => status,
        "signature" => SusanPoke.verify(body, key, signature) == :ok,
        "delivery" => request.delivery_id,
        "opens" => poke.route == @route and poke.kind == :needs_input,
        "stranger" => PushPoke.open(request.ciphertext, stranger, request.deployment),
        "content_free" =>
          not String.contains?(body, ["threads", "7a1c0e44", device.id, "push-owner"])
      }
      |> Map.update!("stranger", &(&1 == {:error, :authentication}))
    end)
  end
end

PushNotificationsProbe.run()
