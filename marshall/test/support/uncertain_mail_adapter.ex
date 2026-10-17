defmodule Marshall.Test.UncertainMailAdapter do
  @moduledoc "Test-only mail adapter that simulates acceptance with a lost result."
  use Swoosh.Adapter

  @impl true
  @spec deliver(Swoosh.Email.t(), Keyword.t()) :: {:ok, map()} | {:error, :lost_result}
  def deliver(email, config) do
    owner = Keyword.fetch!(config, :owner)
    counter = Keyword.fetch!(config, :counter)
    uncertain_attempts = Keyword.fetch!(config, :uncertain_attempts)
    attempt = Agent.get_and_update(counter, fn previous -> {previous + 1, previous + 1} end)

    send(owner, {
      :auth_mail_attempt,
      attempt,
      Map.fetch!(email.headers, "Message-ID"),
      :crypto.hash(:sha256, email.text_body),
      :crypto.hash(:sha256, email.html_body)
    })

    if attempt <= uncertain_attempts, do: {:error, :lost_result}, else: {:ok, %{}}
  end
end
