defmodule MarshallWeb.Admin.JobsLive do
  use MarshallWeb, :live_view
  alias Marshall.Administration
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  defp states do
    [
    {gettext("Queued"), :available},
    {gettext("Suspended"), :suspended},
    {gettext("Scheduled"), :scheduled},
    {gettext("Running"), :executing},
    {gettext("Retrying"), :retryable},
    {gettext("Succeeded"), :completed},
    {gettext("Failed"), :discarded},
    {gettext("Cancelled"), :cancelled}
  ]

  end

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 5_000)

    {:ok,
     socket
     |> assign(
       filters: %{},
       next_cursor: nil,
       counts: %{},
       empty?: true,
       job: nil,
       subject: nil,
       next_events_cursor: nil,
       events_before: nil,
       job_id: nil,
       refreshed_at: nil,
       states: states(),
       retry_request_id: Ash.UUID.generate()
     )
     |> stream(:jobs, [])
     |> stream(:events, [])}
  end

  @impl true
  def handle_params(params, _, socket) do
    case socket.assigns.live_action do
      :index ->
        filters = Map.take(params, ["state", "queue", "worker", "before", "range"])

        {:noreply,
         socket |> assign(filters: filters, form: to_form(filters, as: :filters)) |> refresh()}

      :show ->
        {:noreply,
         socket
         |> assign(
           job_id: params["id"],
           events_before: params["events_before"],
           retry_request_id: Ash.UUID.generate()
         )
         |> refresh()}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters =
      params
      |> Map.take(["state", "queue", "worker", "range"])
      |> Map.reject(fn {_, value} -> value == "" end)

    {:noreply, push_patch(socket, to: ~p"/admin/jobs?#{filters}")}
  end

  def handle_event("retry", _, %{assigns: %{live_action: :show}} = socket) do
    case Administration.retry_job(
           %{id: socket.assigns.job_id, request_id: socket.assigns.retry_request_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Retry queued. The related operation will recheck its current state.")
         )
         |> assign(:retry_request_id, Ash.UUID.generate())
         |> refresh()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("This job could not be retried. Its state or your access may have changed.")
         )
         |> refresh()}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, gettext("Invalid request."))}

  defp refresh(%{assigns: %{live_action: :index}} = socket) do
    filters = socket.assigns.filters

    since =
      case filters["range"] do
        "day" -> DateTime.add(DateTime.utc_now(), -86_400)
        "week" -> DateTime.add(DateTime.utc_now(), -7 * 86_400)
        "month" -> DateTime.add(DateTime.utc_now(), -30 * 86_400)
        _ -> nil
      end

    request = %{
      state: present(filters["state"]),
      queue: present(filters["queue"]),
      worker: present(filters["worker"]),
      before: present(filters["before"]),
      since: since
    }

    case Administration.jobs(request, actor: socket.assigns.current_user) do
      {:ok, page} ->
        socket
        |> stream(:jobs, page.items, reset: true)
        |> assign(
          next_cursor: page.next_cursor,
          counts: page.counts,
          empty?: page.items == [],
          refreshed_at: DateTime.utc_now()
        )

      {:error, _} ->
        socket
        |> stream(:jobs, [], reset: true)
        |> assign(empty?: true, counts: %{}, next_cursor: nil)
        |> put_flash(:error, gettext("Jobs are unavailable or the filters are invalid."))
    end
  end

  defp refresh(socket) do
    case Administration.job(
           %{id: socket.assigns.job_id, events_before: socket.assigns.events_before},
           actor: socket.assigns.current_user
         ) do
      {:ok, result} ->
        socket
        |> assign(
          job: result.job,
          subject: result.subject,
          next_events_cursor: result.next_events_cursor,
          refreshed_at: DateTime.utc_now()
        )
        |> stream(:events, result.events, reset: true)

      {:error, _} ->
        socket
        |> assign(job: nil, subject: nil, next_events_cursor: nil)
        |> stream(:events, [], reset: true)
        |> put_flash(:error, gettext("This job is unavailable or its history has expired."))
    end
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp label(state),
    do: Enum.find_value(states(), gettext("Unknown"), fn {label, value} -> if value == state, do: label end)

  defp duration(nil), do: "—"
  defp duration(milliseconds), do: "#{Float.round(milliseconds / 1000, 2)} s"
  defp age(nil), do: "—"
  defp age(seconds) when seconds < 60, do: "#{seconds} s"
  defp age(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"
  defp age(seconds), do: "#{div(seconds, 3600)} h"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="admin"
      admin_active="jobs"
    >
      <section id="admin-jobs" class="stack">
        <UI.heading
          title={if @live_action == :index, do: gettext("Jobs"), else: gettext("Job details")}
          subtitle={gettext("Background work run by Oban. A successful job may have dispatched work whose physical outcome is still pending; follow the related operation for completion.")}
        >
          <:actions>
            <span class="muted">{gettext("Updated")}
            <.timestamp at={@refreshed_at} zone={@time_zone} format={:datetime_seconds} />
            {gettext("· every 5 seconds")}</span>
          </:actions>
        </UI.heading>
        <%= if @live_action == :index do %>
          <div id="job-state-counts" class="table-flow">
            <table>
              <thead>
                <tr>
                  <th :for={{title, _state} <- @states} class="num">{title}</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td :for={{_title, state} <- @states} class="num">
                    <.link patch={~p"/admin/jobs?#{%{state: state}}"}>
                      <strong>{Map.get(@counts, state, "—")}</strong>
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="muted">
            {gettext("Counts cover current and recently retained raw jobs. The list includes redacted history for up to 30 days; older history pruned before deployment is unavailable.")}
          </p>
          <.form for={@form} id="job-filters" phx-submit="filter" class="panel stack">
            <h2>{gettext("Filter")}</h2>
            <div class="grid">
              <.input
                field={@form[:state]}
                type="select"
                label={gettext("State")}
                options={@states}
                prompt={gettext("All states")}
              />
              <.input field={@form[:queue]} label={gettext("Queue")} placeholder={gettext("Any queue")} maxlength="128" />
              <.input
                field={@form[:worker]}
                label={gettext("Worker")}
                placeholder={gettext("Exact worker name")}
                maxlength="256"
              />
              <.input
                field={@form[:range]}
                type="select"
                label={gettext("Last updated")}
                options={[
                  {gettext("All retained"), "all"},
                  {gettext("24 hours"), "day"},
                  {gettext("7 days"), "week"},
                  {gettext("30 days"), "month"}
                ]}
              />
            </div>
            <div class="row actions">
              <button type="submit" class="console-button primary">{gettext("Filter jobs")}</button>
            </div>
          </.form>
          <div class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">{gettext("Job")}</th>
                  <th class="width-min">{gettext("State")}</th>
                  <th class="width-auto">{gettext("Queue / worker")}</th>
                  <th class="width-min num">{gettext("Attempts")}</th>
                  <th class="width-min num">{gettext("Waiting")}</th>
                  <th class="width-min num">{gettext("Duration")}</th>
                </tr>
              </thead>
              <tbody id="job-rows" phx-update="stream">
                <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}>
                  <td><.link navigate={~p"/admin/jobs/#{job.id}"}>#{job.id}</.link></td>
                  <td class="nowrap">
                    <span class="status-label" data-tone={job_tone(job.state)}>{label(job.state)}</span>
                    <span :if={!job.raw_present} class="muted"> {gettext("Archived")}</span>
                  </td>
                  <td class="break">
                    {job.queue}<br /><span class="muted" title={job.worker}>{job.worker}</span>
                  </td>
                  <td class="num">{job.attempt} / {job.max_attempts}</td>
                  <td class="num">{age(job.queue_age_seconds)}</td>
                  <td class="num">{duration(job.duration_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@empty?} id="jobs-empty" class="empty-state">
            {gettext("No jobs match these filters.")}
          </p>
          <nav aria-label={gettext("Job pages")} class="row">
            <.link :if={@filters["before"]} patch={~p"/admin/jobs?#{Map.delete(@filters, "before")}"}>{gettext("← First page")}</.link>
            <.link
              :if={@next_cursor}
              id="jobs-next"
              patch={~p"/admin/jobs?#{Map.put(@filters, "before", @next_cursor)}"}
            >{gettext("Older jobs →")}</.link>
          </nav>
        <% else %>
          <p><.link navigate={~p"/admin/jobs"}>{gettext("← Jobs")}</.link></p>
          <div :if={@job} id="job-detail" class="stack">
            <UI.panel title={gettext("Job #%{id}", id: @job.id)}>
              <:actions>
                <span class="status-label" data-tone={job_tone(@job.state)}>{label(@job.state)}</span>
                <button
                  :if={@admin_authorized and @job.retryable}
                  id="retry-job"
                  phx-click="retry"
                  data-confirm={gettext("Queue another attempt? The operation will recheck its current state.")}
                  class="console-button primary"
                >{gettext("Retry job")}</button>
                <span :if={!@job.raw_present} class="muted">{gettext("Archived history · retry unavailable")}</span>
              </:actions>
              <.kv>
                <:item title={gettext("Queue")}>{@job.queue}</:item>
                <:item title={gettext("Worker")}><span class="break">{@job.worker}</span></:item>
                <:item title={gettext("Attempts")}>{@job.attempt} / {@job.max_attempts}</:item>
                <:item title={gettext("Created")}>
                  <.timestamp at={@job.inserted_at} zone={@time_zone} format={:datetime_seconds} />
                </:item>
                <:item title={gettext("Scheduled / next retry")}>
                  <.timestamp at={@job.scheduled_at} zone={@time_zone} format={:datetime_seconds} />
                </:item>
                <:item title={gettext("Last attempt started")}>
                  <.timestamp at={@job.attempted_at} zone={@time_zone} format={:datetime_seconds} />
                </:item>
                <:item title={gettext("Last execution duration")}>{duration(@job.duration_ms)}</:item>
                <:item title={gettext("Recorded failures")}>{@job.error_count}</:item>
              </.kv>
            </UI.panel>
            <p :if={@job.failure} id="job-failure" class="error">
              {@job.failure}
            </p>
            <UI.panel :if={@subject} id="job-subject" title={gettext("Related record")}>
              <.kv>
                <:item title={String.capitalize(to_string(@subject.kind))}>
                  <code>{@subject.id}</code>
                </:item>
                <:item :if={Map.has_key?(@subject, :status)} title={gettext("Operation state")}>
                  {@subject.status}
                </:item>
                <:item :if={Map.has_key?(@subject, :finished)} title={gettext("Relocation complete")}>
                  {to_string(@subject.finished)}
                </:item>
              </.kv>
              <p :if={@subject[:vm_id]}>
                <.link navigate={~p"/machines/#{@subject.vm_id}"}>{gettext("Open machine →")}</.link>
              </p>
            </UI.panel>
            <UI.panel id="job-history" title={gettext("Execution history")}>
              <div class="table-flow">
                <table>
                  <thead>
                    <tr>
                      <th class="width-min">{gettext("Captured")}</th>
                      <th class="width-min">{gettext("State")}</th>
                      <th class="width-auto">{gettext("Attempt")}</th>
                    </tr>
                  </thead>
                  <tbody id="job-events" phx-update="stream">
                    <tr :for={{dom_id, event} <- @streams.events} id={dom_id}>
                      <td class="nowrap">
                        <.timestamp
                          at={event.captured_at}
                          zone={@time_zone}
                          format={:datetime_seconds}
                        />
                      </td>
                      <td class="nowrap">
                        <span class="status-label" data-tone={job_tone(event.state)}>{label(
                          event.state
                        )}</span>
                      </td>
                      <td>{gettext("attempt %{attempt} · %{count} recorded failures", attempt: event.attempt, count: event.error_count)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p :if={@next_events_cursor}>
                <.link
                  id="older-job-events"
                  patch={~p"/admin/jobs/#{@job.id}?#{%{events_before: @next_events_cursor}}"}
                >{gettext("Older transitions →")}</.link>
              </p>
            </UI.panel>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  @spec job_tone(atom()) :: String.t() | nil
  defp job_tone(:discarded), do: "danger"
  defp job_tone(:completed), do: "success"
  defp job_tone(_), do: nil
end
