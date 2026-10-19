defmodule Susan.Provider.HTTP do
  @moduledoc """
  The injectable provider transport. Production uses `Susan.Provider.Finch`;
  tests and machine fixtures substitute a fake through the `:provider_http`
  application environment. Implementations return only the status, lower-case
  response headers and a bounded body, or `{:error, :transport}`.
  """

  @type header :: {String.t(), String.t()}
  @type response :: {:ok, 100..599, [header()], binary()} | {:error, :transport}

  @callback request(:post, String.t(), [header()], iodata()) :: response()

  @spec request(:post, String.t(), [header()], iodata()) :: response()
  def request(method, url, headers, body) do
    Application.get_env(:susan, :provider_http, Susan.Provider.Finch).request(
      method,
      url,
      headers,
      body
    )
  end
end
