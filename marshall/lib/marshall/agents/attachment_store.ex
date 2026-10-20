defmodule Marshall.Agents.AttachmentStore do
  @moduledoc "Encrypted-at-rest local attachment blob storage with opaque keys."

  @type key :: String.t()
  @type error :: :invalid_key | :not_found | :io_error

  @spec put(key(), binary()) :: :ok | {:error, error()}
  def put(key, bytes) when is_binary(key) and is_binary(bytes) do
    with :ok <- validate_key(key),
         directory = root() |> Path.join(Path.dirname(key)),
         :ok <- File.mkdir_p(directory),
         temporary =
           Path.join(directory, "." <> Path.basename(key) <> ".tmp-" <> Ecto.UUID.generate()),
         :ok <- File.write(temporary, bytes, [:binary]),
         :ok <- File.rename(temporary, Path.join(root(), key)) do
      :ok
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :io_error}
  end

  @spec get(key()) :: {:ok, binary()} | {:error, error()}
  def get(key) when is_binary(key) do
    with :ok <- validate_key(key),
         {:ok, bytes} <- File.read(Path.join(root(), key)) do
      {:ok, bytes}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :io_error}
  end

  @spec delete(key()) :: :ok | {:error, error()}
  def delete(key) when is_binary(key) do
    with :ok <- validate_key(key) do
      case File.rm(Path.join(root(), key)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _} -> {:error, :io_error}
      end
    end
  end

  defp root,
    do:
      Application.get_env(:marshall, __MODULE__, [])
      |> Keyword.get(:root, Path.join(System.tmp_dir!(), "marshall-attachments"))

  defp validate_key(key) do
    if byte_size(key) in 1..256 and Path.type(key) == :relative and
         not String.contains?(key, ["..", "\\"]), do: :ok, else: {:error, :invalid_key}
  end
end