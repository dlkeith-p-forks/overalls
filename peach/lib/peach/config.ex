defmodule Peach.Config do
  @type t :: %{socket: binary(), host_id: binary(), control: map()}
  @spec load(binary() | nil) :: t()
  def load(nil), do: load("/etc/peach/config.json")

  def load(path) do
    {:ok, value} = path |> File.read!() |> Jason.decode()

    %{
      socket: value["socket"],
      host_id: value["host_id"],
      control: %{
        origin: value["control_plane"],
        token: File.read!(value["credential_file"]) |> String.trim(),
        host_id: value["host_id"],
        ca_file: value["ca_file"]
      }
    }
  end
end
