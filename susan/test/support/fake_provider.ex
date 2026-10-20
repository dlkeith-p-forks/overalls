defmodule Susan.FakeProvider do
  @moduledoc """
  A scripted provider transport for tests. Responses are taken in order for
  each origin (falling back to 200), and every request is recorded so tests
  can assert exactly how many provider sends happened.
  """
  @behaviour Susan.Provider.HTTP

  @name __MODULE__

  @spec reset() :: :ok
  def reset do
    case Process.whereis(@name) do
      nil ->
        {:ok, _} = Agent.start(fn -> %{script: [], requests: []} end, name: @name)
        :ok

      _ ->
        Agent.update(@name, fn _ -> %{script: [], requests: []} end)
    end
  end

  @doc "Queue responses: `{origin_prefix, status, headers, body}` or `{origin_prefix, :transport}`."
  @spec script([tuple()]) :: :ok
  def script(responses), do: Agent.update(@name, &%{&1 | script: &1.script ++ responses})

  @spec requests() :: [%{url: String.t(), headers: [{String.t(), String.t()}], body: binary()}]
  def requests, do: Agent.get(@name, &Enum.reverse(&1.requests))

  @impl true
  def request(:post, url, headers, body) do
    Agent.get_and_update(@name, fn state ->
      record = %{url: url, headers: headers, body: IO.iodata_to_binary(body)}
      {response, script} = take(state.script, url)
      {response, %{state | script: script, requests: [record | state.requests]}}
    end)
  end

  defp take(script, url) do
    case Enum.split_while(script, fn entry -> not String.starts_with?(url, elem(entry, 0)) end) do
      {before, [{_, :transport} | rest]} ->
        {{:error, :transport}, before ++ rest}

      {before, [{_, status, headers, body} | rest]} ->
        {{:ok, status, headers, body}, before ++ rest}

      {_, []} ->
        {default(url), script}
    end
  end

  defp default("https://oauth2.googleapis.com" <> _),
    do:
      {:ok, 200, [],
       ~s({"access_token":"fake-access-token","expires_in":3600,"token_type":"Bearer"})}

  defp default("https://login.microsoftonline.com" <> _),
    do:
      {:ok, 200, [],
       ~s({"access_token":"fake-wns-token","expires_in":3600,"token_type":"Bearer"})}

  defp default(_url), do: {:ok, 200, [], ~s({"name":"projects/p/messages/1"})}
end
