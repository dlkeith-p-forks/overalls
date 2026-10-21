defmodule Peach.Fixtures do
  @moduledoc "Synthetic reflection bindings and snapshots for tests."

  @host "11111111-1111-4111-8111-111111111111"
  @vm "33333333-3333-4333-8333-333333333333"

  @spec host() :: binary()
  def host, do: @host

  @spec other_host() :: binary()
  def other_host, do: "44444444-4444-4444-8444-444444444444"

  @spec config(map()) :: map()
  def config(control),
    do: %{host_id: @host, socket: "/run/peach/reflection.sock", control: control}

  @spec binding(map()) :: map()
  def binding(overrides \\ %{}) do
    Map.merge(
      %{
        "host_id" => @host,
        "vm_id" => @vm,
        "placement_id" => "55555555-5555-4555-8555-555555555555",
        "execution_epoch" => 7
      },
      overrides
    )
  end

  @spec encode(map()) :: binary()
  def encode(binding), do: binding |> Jason.encode!() |> Base.url_encode64(padding: false)

  @spec snapshot(map()) :: map()
  def snapshot(guest_overrides \\ %{}) do
    %{
      "version" => 1,
      "guest" =>
        Map.merge(
          %{
            "id" => @vm,
            "name" => "guest",
            "profile" => "customer",
            "architecture" => "x86_64",
            "operating_system" => "linux",
            "vcpu" => 2,
            "memory_bytes" => 1,
            "disk_bytes" => 1,
            "image_id" => "image",
            "generation" => 1,
            "state" => "running",
            "owner_email" => "owner@example.invalid",
            "team_name" => nil,
            "node" => %{"id" => @host, "name" => "node"},
            "labels" => ["build"],
            "comment" => ""
          },
          guest_overrides
        ),
      "integrations" => [
        %{
          "name" => "llm",
          "type" => "llm",
          "comment" => "",
          "url" => "https://llm.internal",
          "paths" => [%{"path" => "/", "description" => "Service endpoint"}],
          "help" => "curl --fail --silent https://llm.internal/v1/models",
          "headers" => []
        }
      ]
    }
  end
end
