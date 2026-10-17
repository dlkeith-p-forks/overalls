defmodule Marshall.Threads.TitleWorker do
  @moduledoc "Generates a bounded title after thread admission."
  use Oban.Worker, queue: :default, max_attempts: 3
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.{Thread, Title}

  @impl true
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"thread_id" => id}}) do
    case Ledger.read!(Thread, id: id) do
      [%Thread{objective: objective} = thread] ->
        _ = Ledger.update!(thread, :set_title, %{title: Title.generate(objective)})
        :ok

      _ ->
        :ok
    end
  end
end
