defmodule Marshall.Agents.AttachmentStore do
  @moduledoc "Encrypted-at-rest local attachment blob storage with opaque keys."

  # @cc [owner:ghuntley,label:security] attachment-store-confidentiality
  # Attachment bytes MUST be encrypted before they are written to the blob
  # store, and reads MUST authenticate and decrypt the stored envelope.

  @type key :: String.t()
  @type error :: :invalid_key | :not_found | :io_error

  @magic "MARATT1"
  @nonce_bytes 12
  @tag_bytes 16

  @spec put(key(), binary()) :: :ok | {:error, error()}
  def put(key, bytes) when is_binary(key) and is_binary(bytes) do
    with :ok <- validate_key(key),
         directory = root() |> Path.join(Path.dirname(key)),
         :ok <- File.mkdir_p(directory),
         temporary =
           Path.join(directory, "." <> Path.basename(key) <> ".tmp-" <> Ecto.UUID.generate()),
         :ok <- File.write(temporary, encrypt(bytes), [:binary]),
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
         {:ok, envelope} <- File.read(Path.join(root(), key)),
         {:ok, bytes} <- decrypt(envelope) do
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

  @spec encrypt(binary()) :: binary()
  defp encrypt(bytes) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        encryption_key(),
        nonce,
        bytes,
        @magic,
        @tag_bytes,
        true
      )

    <<@magic::binary, nonce::binary, tag::binary, ciphertext::binary>>
  end

  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :io_error}
  defp decrypt(
         <<@magic::binary, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
           ciphertext::binary>>
       ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           encryption_key(),
           nonce,
           ciphertext,
           @magic,
           tag,
           false
         ) do
      :error -> {:error, :io_error}
      bytes when is_binary(bytes) -> {:ok, bytes}
    end
  rescue
    _ -> {:error, :io_error}
  end

  defp decrypt(_), do: {:error, :io_error}

  @spec encryption_key() :: <<_::256>>
  defp encryption_key do
    configured = Application.get_env(:marshall, __MODULE__, []) |> Keyword.get(:encryption_key)

    case configured do
      key when is_binary(key) and byte_size(key) == 32 -> key
      _ -> raise ArgumentError, "attachment encryption key is missing or invalid"
    end
  end
end
