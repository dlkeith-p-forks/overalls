defmodule MarshallWeb.InferenceLive do
  use MarshallWeb, :live_view
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(filters: %{}, next: nil, totals: %{}, chart: [], empty?: true)
     |> assign(form: to_form(%{"provider" => "", "model" => ""}, as: :filter))
     |> stream(:usage, [])}
  end

  @impl true
  def handle_params(params, _, socket) do
    filters = Map.take(params, ~w(provider model after))
    action = if socket.assigns.live_action == :admin, do: :list_usage_for_admin, else: :list_usage

    case apply(Marshall.Inference, action, [
           %{filters: filters},
           [actor: socket.assigns.current_user]
         ]) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(
           filters: filters,
           next: page.next,
           totals: page.totals,
           chart: page.chart,
           empty?: page.rows == [],
           form: to_form(Map.merge(%{"provider" => "", "model" => ""}, filters), as: :filter)
         )
         |> stream(:usage, page.rows, reset: true)}

      _ ->
        {:noreply,
         socket |> put_flash(:error, "AI usage is unavailable.") |> redirect(to: ~p"/machines")}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => filters}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         base(socket.assigns.live_action) <>
           "?" <> URI.encode_query(Map.take(filters, ~w(provider model)))
     )}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}
  defp base(:admin), do: "/admin/usage"
  defp base(_), do: "/usage"
  defp number(nil), do: "0"
  defp number(%Decimal{} = number), do: Decimal.to_string(number, :normal)
  defp number(number), do: to_string(number)
  defp tokens(nil, _), do: "Unknown"

  defp tokens(completion, field) do
    case completion["tokens"][field] do
      nil -> "Unknown"
      value -> to_string(value)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active={if @live_action == :admin, do: "admin", else: "usage"}
      admin_active="usage"
    >
      <section id="inference-usage" class="stack">
        <UI.heading
          title={if @live_action == :admin, do: "Fleet AI usage", else: "Your AI usage"}
          subtitle="AI usage is attributed to each machine’s owner. Incomplete AI usage remains unknown."
        >
          <:actions>
            <.link
              id="usage-export"
              href={base(@live_action) <> "/export?" <> URI.encode_query(@filters)}
              class="console-button"
            >Export AI usage</.link>
          </:actions>
        </UI.heading>
        <.kv id="usage-totals">
          <:item title="AI requests">{number(@totals[:requests])}</:item>
          <:item title="Incomplete AI reports">{number(@totals[:unknown_requests])}</:item>
          <:item title="Reported input tokens">{number(@totals[:input_tokens])}</:item>
          <:item title="Reported output tokens">{number(@totals[:output_tokens])}</:item>
        </.kv>
        <UI.panel title="AI requests · last 30 days">
          <figure>
            <pre
              id="usage-chart"
              class="columns"
              role="img"
              aria-label="Daily AI request counts over the past 30 days"
            >{usage_chart(@chart)}</pre>
            <figcaption>
              One column per day, oldest first; eight rows of █ scale to the busiest day. Labels mark the day of the month.
            </figcaption>
          </figure>
        </UI.panel>
        <.form for={@form} id="usage-filter" phx-submit="filter" class="panel stack">
          <h2>Filter</h2>
          <div class="grid">
            <.input
              field={@form[:provider]}
              type="select"
              label="Provider"
              options={[{"All providers", ""}, {"OpenAI", "openai"}, {"Anthropic", "anthropic"}]}
            />
            <.input field={@form[:model]} label="Model" placeholder="Exact model ID" maxlength="256" />
          </div>
          <div class="row actions">
            <button class="console-button primary">Apply</button>
          </div>
        </.form>
        <div :if={!@empty?} class="table-flow">
          <table>
            <thead>
              <tr>
                <th class="width-min">Time</th>
                <th class="width-auto">Model</th>
                <th class="width-min num">Input tokens</th>
                <th class="width-min num">Output tokens</th>
                <th class="width-min">Outcome</th>
                <th class="width-min">Details</th>
              </tr>
            </thead>
            <tbody id="usage-rows" phx-update="stream">
              <tr :for={{id, row} <- @streams.usage} id={id}>
                <td class="nowrap">
                  <.timestamp at={row.inserted_at} zone={@time_zone} format={:datetime_seconds} />
                </td>
                <td class="break">
                  <strong>{row.model}</strong><br /><span class="muted">{row.provider}</span>
                </td>
                <td class="num">{tokens(row.completion, "input_tokens")}</td>
                <td class="num">{tokens(row.completion, "output_tokens")}</td>
                <td>{if row.completion, do: row.completion["outcome"], else: "Unreported"}</td>
                <td>
                  <details>
                    <summary>Inspect</summary>
                    <dl class="kv stacked">
                      <div>
                        <dt>Token cost estimate · USD</dt>
                        <dd>
                          {get_in(row.completion || %{}, ["cost_estimate", "usd"]) || "Unknown"}
                        </dd>
                      </div>
                      <div>
                        <dt>Pricing source / version</dt>
                        <dd>
                          {get_in(row.completion || %{}, ["cost_estimate", "source"]) || "Unknown"} / {get_in(
                            row.completion || %{},
                            ["cost_estimate", "version"]
                          ) || "Unknown"}
                        </dd>
                      </div>
                      <div>
                        <dt>AI request</dt><dd><code>{row.id}</code></dd>
                      </div>
                      <div>
                        <dt>Machine</dt><dd><code>{row.vm_id}</code></dd>
                      </div>
                      <div>
                        <dt>Placement / epoch</dt>
                        <dd><code>{row.placement_id}</code> / {row.execution_epoch}</dd>
                      </div>
                      <div>
                        <dt>AI usage report</dt>
                        <dd>
                          {if row.completion, do: row.completion["completeness"], else: "unknown"}
                        </dd>
                      </div>
                    </dl>
                  </details>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@empty?} id="usage-empty" class="empty-state">
          No AI requests match these filters.
        </p>
        <p :if={@next}>
          <.link
            id="usage-next"
            patch={base(@live_action) <> "?" <> URI.encode_query(Map.put(@filters, "after", @next))}
          >Older AI requests →</.link>
        </p>
      </section>
    </Layouts.app>
    """
  end

  @chart_rows 8
  @spec usage_chart([%{day: String.t(), totals: map()}]) :: String.t()
  defp usage_chart(days) do
    counts = Enum.map(days, &(&1.totals.requests || 0))
    peak = Enum.max(counts, fn -> 1 end) |> max(1)

    rows =
      for row <- @chart_rows..1//-1 do
        Enum.map_join(counts, "", fn count ->
          if count * @chart_rows >= row * peak, do: "█", else: " "
        end)
      end

    # One label per five columns keeps day numbers readable at 1ch per column.
    labels =
      days
      |> Enum.chunk_every(5)
      |> Enum.map_join("", fn [first | _] = chunk ->
        String.pad_trailing(String.slice(first.day, -2, 2), length(chunk))
      end)

    Enum.join(rows ++ [String.duplicate("─", length(counts)), labels], "\n")
  end
end
