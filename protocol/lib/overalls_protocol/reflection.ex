defmodule OverallsProtocol.Reflection do
  @moduledoc "Closed, secret-free guest reflection projections."

  @version 1
  @max_labels 32
  @max_comment_bytes 2048
  @os ~w(linux windows freebsd illumos unknown)
  @profiles ~w(customer standard oss inception)
  @integration_types ~w(reflection llm http vm)

  @type operating_system :: :linux | :windows | :freebsd | :illumos | :unknown
  @type guest :: map()
  @type integration :: map()
  @type snapshot :: %{version: 1, guest: guest(), integrations: [integration()]}

  @spec version() :: 1
  def version, do: @version

  @spec comment(term()) :: {:ok, String.t()} | {:error, :invalid_comment}
  def comment(value) when is_binary(value) and byte_size(value) <= @max_comment_bytes do
    if String.valid?(value) and not String.contains?(value, ["\0"]),
      do: {:ok, value},
      else: {:error, :invalid_comment}
  end

  def comment(_), do: {:error, :invalid_comment}

  @spec labels(term()) :: {:ok, [String.t()]} | {:error, :invalid_labels}
  def labels(values) when is_list(values) and length(values) <= @max_labels do
    if Enum.all?(
         values,
         &(is_binary(&1) and byte_size(&1) in 1..64 and String.valid?(&1) and
             not String.contains?(&1, ["\0", "\n", "\r"]))
       ) do
      {:ok, Enum.uniq(values)}
    else
      {:error, :invalid_labels}
    end
  end

  def labels(_), do: {:error, :invalid_labels}

  @spec os(term()) :: {:ok, operating_system()} | {:error, :invalid_os}
  def os(value) when is_binary(value) do
    if value in @os, do: {:ok, String.to_existing_atom(value)}, else: {:error, :invalid_os}
  rescue
    ArgumentError -> {:error, :invalid_os}
  end

  def os(_), do: {:error, :invalid_os}

  @spec snapshot(term()) :: {:ok, snapshot()} | {:error, :invalid_snapshot}
  def snapshot(%{"version" => 1, "guest" => guest, "integrations" => integrations} = value)
      when map_size(value) == 3 and is_map(guest) and is_list(integrations) and
             length(integrations) <= 128 do
    with :ok <- validate_guest(guest),
         true <- Enum.all?(integrations, &valid_integration?/1) do
      {:ok, %{version: 1, guest: guest, integrations: integrations}}
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  def snapshot(_), do: {:error, :invalid_snapshot}

  @spec root(snapshot()) :: map()
  def root(%{version: 1, guest: guest, integrations: integrations}) do
    %{"version" => 1, "guest" => guest, "integrations" => integrations, "paths" => paths()}
  end

  @spec paths() :: [map()]
  def paths do
    [
      %{"path" => "/guest", "description" => "Guest metadata"},
      %{"path" => "/integrations", "description" => "Authorized integrations"}
    ]
  end

  defp validate_guest(value) do
    required =
      ~w(id name profile architecture operating_system vcpu memory_bytes disk_bytes image_id generation state owner_email team_name node labels comment)

    with true <- Enum.sort(Map.keys(value)) == Enum.sort(required),
         true <- is_binary(value["id"]) and OverallsProtocol.uuid?(value["id"]),
         true <- is_binary(value["name"]) and byte_size(value["name"]) in 1..63,
         true <- value["profile"] in @profiles,
         true <- value["architecture"] == "x86_64",
         {:ok, _} <- os(value["operating_system"]),
         true <-
           Enum.all?(
             [:vcpu, :memory_bytes, :disk_bytes, :generation],
             &(is_integer(value[Atom.to_string(&1)]) and value[Atom.to_string(&1)] > 0)
           ),
         true <- is_binary(value["image_id"]),
         true <- byte_size(value["image_id"]) in 1..128,
         true <- is_binary(value["owner_email"]),
         true <- is_nil(value["team_name"]) or is_binary(value["team_name"]),
         true <- valid_node?(value["node"]),
         {:ok, _} <- labels(value["labels"]),
         {:ok, _} <- comment(value["comment"]),
         true <- value["state"] == "running" do
      :ok
    else
      _ -> {:error, :invalid_guest}
    end
  end

  defp valid_integration?(value) when is_map(value) do
    required = ~w(name type comment url paths help headers)

    Enum.sort(Map.keys(value)) == Enum.sort(required) and
      is_binary(value["name"]) and value["type"] in @integration_types and
      match?({:ok, _}, comment(value["comment"])) and is_binary(value["url"]) and
      is_list(value["paths"]) and length(value["paths"]) <= 128 and is_binary(value["help"]) and
      byte_size(value["help"]) <= 4096 and is_list(value["headers"]) and
      length(value["headers"]) <= 64 and
      Enum.all?(value["headers"], &valid_header?/1) and
      Enum.all?(value["paths"], &valid_path?/1)
  end

  defp valid_integration?(_), do: false

  defp valid_node?(%{"id" => id, "name" => name} = node)
       when map_size(node) == 2 and is_binary(id) and is_binary(name) do
    OverallsProtocol.uuid?(id) and byte_size(name) in 1..128
  end

  defp valid_node?(_), do: false

  defp valid_header?(%{"name" => name, "kind" => kind} = header)
       when map_size(header) == 2 and is_binary(name) and is_binary(kind),
       do: byte_size(name) in 1..128 and kind in ["authorization", "content_type", "custom"]

  defp valid_header?(_), do: false

  defp valid_path?(%{"path" => path, "description" => description} = value)
       when map_size(value) == 2 and is_binary(path) and is_binary(description),
       do:
         byte_size(path) in 1..256 and String.starts_with?(path, "/") and
           byte_size(description) <= 512

  defp valid_path?(_), do: false
end
