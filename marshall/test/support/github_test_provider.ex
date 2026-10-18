defmodule Marshall.GitHubTestProvider do
  @behaviour Marshall.GitHub.Provider
  alias Marshall.GitHub.{Grant, Provider}

  @impl true
  @spec exchange(binary(), binary()) :: {:ok, Grant.t()} | {:error, :unavailable}
  def exchange(code, verifier) do
    send(self(), {:exchanged, code, verifier})

    case Process.get(:github_test_gate) do
      {owner, ref} ->
        send(owner, {:github_exchange_started, self(), ref})

        receive do
          {:release, ^ref} -> :ok
        after
          10_000 -> raise "synthetic GitHub exchange gate expired"
        end

      nil ->
        :ok
    end

    {:ok,
     %Grant{
       access_token: "synthetic-access",
       refresh_token: "synthetic-refresh",
       expires_in: 28_800,
       refresh_expires_in: 1_000_000,
       scopes: Provider.scopes()
     }}
  end

  @impl true
  @spec refresh(binary()) :: {:ok, Grant.t()} | {:error, :unavailable}
  def refresh(token) do
    send(self(), {:refreshed, token})

    case Process.get(:github_refresh_mode, :success) do
      :success -> exchange("refresh", "verifier")
      :ambiguous -> {:error, :unavailable}
    end
  end

  @impl true
  @spec identity(binary()) :: {:ok, Marshall.GitHub.Provider.identity()}
  def identity(_), do: {:ok, %{id: Process.get(:github_identity, 42), login: "synthetic-user"}}
  @impl true
  @spec revoke(binary()) :: :ok
  def revoke(token) do
    send(self(), {:revoked, token})
    :ok
  end

  @impl true
  @spec revoke_token(binary()) :: :ok
  def revoke_token(token) do
    send(self(), {:revoked_token, token})
    :ok
  end
end
