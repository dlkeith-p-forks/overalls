defmodule OverallsProtocol.EditorConnect do
  @moduledoc "Closed editor principal/execution preface, followed by an opaque guest stream."
  alias OverallsProtocol.{EditorName, EditorRelease}
  @maximum 2048
  @fields ~w(vm_id host_id placement_id session_id execution_epoch generation label service port user_id guest_account_id uid username editor_protocol editor_commit editor_release editor_origin)a
  @type binding :: %{
          vm_id: String.t(),
          host_id: String.t(),
          placement_id: String.t(),
          session_id: String.t(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          label: String.t(),
          service: :editor,
          port: 4444,
          user_id: String.t(),
          guest_account_id: String.t(),
          uid: 200_000..999_999,
          username: String.t(),
          editor_protocol: 1,
          editor_commit: String.t(),
          editor_release: String.t(),
          editor_origin: String.t()
        }

  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  # @cc [owner:ghuntley,label:security;protocol] editor-preface-required-principal
  # Every preface MUST retain the entire principal, account incarnation, execution
  # and release binding. No address, executable, path or optional web authority is
  # accepted. The trusted connector supplies this document, never browser headers.
  @spec decode(term()) :: {:ok, binding()} | {:error, :invalid_editor_connect}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum do
    with {:ok, %{"version" => 1, "binding" => wire} = envelope} <- JSON.decode(bytes),
         true <- map_size(envelope) == 2,
         {:ok, binding} <- from_wire(wire),
         do: {:ok, binding},
         else: (_ -> {:error, :invalid_editor_connect})
  end

  def decode(_), do: {:error, :invalid_editor_connect}

  @spec from_wire(term()) :: {:ok, binding()} | {:error, :invalid_editor_connect}
  def from_wire(%{"service" => "editor"} = wire) when map_size(wire) == 17 do
    if Enum.all?(@fields, &Map.has_key?(wire, Atom.to_string(&1))) do
      binding =
        Map.new(@fields, &{&1, Map.fetch!(wire, Atom.to_string(&1))})
        |> Map.put(:service, :editor)

      if valid?(binding), do: {:ok, binding}, else: {:error, :invalid_editor_connect}
    else
      {:error, :invalid_editor_connect}
    end
  end

  def from_wire(_), do: {:error, :invalid_editor_connect}

  @spec encode(binding()) :: {:ok, binary()} | {:error, :invalid_editor_connect}
  def encode(binding) do
    if valid?(binding),
      do: {:ok, JSON.encode!(%{version: 1, binding: binding})},
      else: {:error, :invalid_editor_connect}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%{service: :editor, port: 4444, editor_protocol: 1} = value)
      when map_size(value) == 17 do
    Enum.all?(@fields, &Map.has_key?(value, &1)) and
      Enum.all?(
        [:vm_id, :host_id, :placement_id, :session_id, :user_id, :guest_account_id],
        &OverallsProtocol.uuid?(value[&1])
      ) and
      Enum.all?(
        [:execution_epoch, :generation],
        &(is_integer(value[&1]) and value[&1] in 1..9_223_372_036_854_775_807)
      ) and
      is_integer(value[:uid]) and value.uid in 200_000..999_999 and username?(value[:username]) and
      EditorRelease.digest?(value[:editor_commit], 40) and
      EditorRelease.digest?(value[:editor_release], 64) and
      value[:label] == EditorName.label(value.vm_id, value.guest_account_id) and
      origin?(value[:editor_origin], value.label)
  end

  def valid?(_), do: false

  @spec username?(term()) :: boolean()
  def username?(value) when is_binary(value) and byte_size(value) in 1..32,
    do:
      Regex.match?(~r/\A[a-z_][a-z0-9_.-]{0,30}[a-z0-9_]\z|\A[a-z_]\z/, value) and
        value not in ~w(root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody ubuntu sshd sudo postgres) and
        not String.starts_with?(value, ["systemd-", "nixbld"])

  def username?(_), do: false

  @spec origin?(term(), String.t()) :: boolean()
  def origin?(value, label)
      when is_binary(value) and byte_size(value) <= 512 and is_binary(label) do
    with {:ok, uri} <- URI.new(value),
         true <- uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo),
         true <- uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment),
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- String.starts_with?(uri.host, label <> "."),
         zone = String.replace_prefix(uri.host, label <> ".", ""),
         true <- zone?(zone),
         suffix = if(uri.port == 443, do: "", else: ":#{uri.port}"),
         true <- value == "https://" <> uri.host <> suffix,
         do: true,
         else: (_ -> false)
  end

  def origin?(_, _), do: false

  @spec zone?(term()) :: boolean()
  def zone?(zone) when is_binary(zone) and byte_size(zone) in 3..189 do
    labels = String.split(zone, ".")

    length(labels) >= 2 and
      Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))
  end

  def zone?(_), do: false

  @spec webview_template(binding()) :: String.t()
  def webview_template(binding) do
    unless valid?(binding), do: raise(ArgumentError, "invalid editor binding")
    uri = URI.parse(binding.editor_origin)
    zone = String.replace_prefix(uri.host, binding.label <> ".", "")
    suffix = if(uri.port == 443, do: "", else: ":#{uri.port}")

    "https://{{uuid}}." <>
      zone <>
      suffix <>
      "/code-assets/" <>
      binding.editor_release <>
      "/out/vs/workbench/contrib/webview/browser/pre/"
  end
end
