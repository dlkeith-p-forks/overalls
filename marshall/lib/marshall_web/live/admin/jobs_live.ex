defmodule MarshallWeb.Admin.JobsLive do
  use MarshallWeb, :live_view
  alias Marshall.Administration
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}
  on_mount {MarshallWeb.LiveAdminAuth, :required}

  defp states do
    [
      {dgettext("admin_jobs", "Queued"), :available},
      {dgettext("admin_jobs", "Suspended"), :suspended},
      {dgettext("admin_jobs", "Scheduled"), :scheduled},
      {dgettext("admin_jobs", "Running"), :executing},
      {dgettext("admin_jobs", "Retrying"), :retryable},
      {dgettext("admin_jobs", "Succeeded"), :completed},
      {dgettext("admin_jobs", "Failed"), :discarded},
      {dgettext("admin_jobs", "Cancelled"), :cancelled}
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
           dgettext(
             "admin_jobs",
             "Retry queued. The related operation will recheck its current state."
           )
         )
         |> assign(:retry_request_id, Ash.UUID.generate())
         |> refresh()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           dgettext(
             "admin_jobs",
             "This job could not be retried. Its state or your access may have changed."
           )
         )
         |> refresh()}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("admin_jobs", "Invalid request."))}

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
        |> put_flash(
          :error,
          dgettext("admin_jobs", "Jobs are unavailable or the filters are invalid.")
        )
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
        |> put_flash(
          :error,
          dgettext("admin_jobs", "This job is unavailable or its history has expired.")
        )
    end
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp label(state),
    do:
      Enum.find_value(states(), dgettext("admin_jobs", "Unknown"), fn {label, value} ->
        if value == state, do: label
      end)

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
          title={
            if @live_action == :index,
              do: dgettext("admin_jobs", "Jobs"),
              else: dgettext("admin_jobs", "Job details")
          }
          subtitle={
            dgettext(
              "admin_jobs",
              "Background work run by Oban. A successful job may have dispatched work whose physical outcome is still pending; follow the related operation for completion."
            )
          }
        >
          <:actions>
            <span class="muted">{dgettext("admin_jobs", "Updated")}
            <.timestamp at={@refreshed_at} zone={@time_zone} format={:datetime_seconds} />
            {dgettext("admin_jobs", "· every 5 seconds")}</span>
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
            {dgettext(
              "admin_jobs",
              "Counts cover current and recently retained raw jobs. The list includes redacted history for up to 30 days; older history pruned before deployment is unavailable."
            )}
          </p>
          <.form for={@form} id="job-filters" phx-submit="filter" class="panel stack">
            <h2>{dgettext("admin_jobs", "Filter")}</h2>
            <div class="grid">
              <.input
                field={@form[:state]}
                type="select"
                label={dgettext("admin_jobs", "State")}
                options={@states}
                prompt={dgettext("admin_jobs", "All states")}
              />
              <.input
                field={@form[:queue]}
                label={dgettext("admin_jobs", "Queue")}
                placeholder={dgettext("admin_jobs", "Any queue")}
                maxlength="128"
              />
              <.input
                field={@form[:worker]}
                label={dgettext("admin_jobs", "Worker")}
                placeholder={dgettext("admin_jobs", "Exact worker name")}
                maxlength="256"
              />
              <.input
                field={@form[:range]}
                type="select"
                label={dgettext("admin_jobs", "Last updated")}
                options={[
                  {dgettext("admin_jobs", "All retained"), "all"},
                  {dgettext("admin_jobs", "24 hours"), "day"},
                  {dgettext("admin_jobs", "7 days"), "week"},
                  {dgettext("admin_jobs", "30 days"), "month"}
                ]}
              />
            </div>
            <div class="row actions">
              <button type="submit" class="console-button primary">{dgettext(
                "admin_jobs",
                "Filter jobs"
              )}</button>
            </div>
          </.form>
          <div class="table-flow">
            <table>
              <thead>
                <tr>
                  <th class="width-min">{dgettext("admin_jobs", "Job")}</th>
                  <th class="width-min">{dgettext("admin_jobs", "State")}</th>
                  <th class="width-auto">{dgettext("admin_jobs", "Queue / worker")}</th>
                  <th class="width-min num">{dgettext("admin_jobs", "Attempts")}</th>
                  <th class="width-min num">{dgettext("admin_jobs", "Waiting")}</th>
                  <th class="width-min num">{dgettext("admin_jobs", "Duration")}</th>
                </tr>
              </thead>
              <tbody id="job-rows" phx-update="stream">
                <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}>
                  <td><.link navigate={~p"/admin/jobs/#{job.id}"}>#{job.id}</.link></td>
                  <td class="nowrap">
                    <span class="status-label" data-tone={job_tone(job.state)}>{label(job.state)}</span>
                    <span :if={!job.raw_present} class="muted">{dgettext("admin_jobs", "Archived")}</span>
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
            {dgettext("admin_jobs", "No jobs match these filters.")}
          </p>
          <nav aria-label={dgettext("admin_jobs", "Job pages")} class="row">
            <.link :if={@filters["before"]} patch={~p"/admin/jobs?#{Map.delete(@filters, "before")}"}>{dgettext(
              "admin_jobs",
              "← First page"
            )}</.link>
            <.link
              :if={@next_cursor}
              id="jobs-next"
              patch={~p"/admin/jobs?#{Map.put(@filters, "before", @next_cursor)}"}
            >{dgettext("admin_jobs", "Older jobs →")}</.link>
          </nav>
        <% else %>
          <p><.link navigate={~p"/admin/jobs"}>{dgettext("admin_jobs", "← Jobs")}</.link></p>
          <div :if={@job} id="job-detail" class="stack">
            <UI.panel title={dgettext("admin_jobs", "Job #%{id}", id: @job.id)}>
              <:actions>
                <span class="status-label" data-tone={job_tone(@job.state)}>{label(@job.state)}</span>
                <button
                  :if={@admin_authorized and @job.retryable}
                  id="retry-job"
                  phx-click="retry"
                  data-confirm={
                    dgettext(
                      "admin_jobs",
                      "Queue another attempt? The operation will recheck its current state."
                    )
                  }
                  class="console-button primary"
                >{dgettext("admin_jobs", "Retry job")}</button>
                <span :if={!@job.raw_present} class="muted">{dgettext(
                  "admin_jobs",
                  "Archived history · retry unavailable"
                )}</span>
              </:actions>
              <.kv>
                <:item title={dgettext("admin_jobs", "Queue")}>{@job.queue}</:item>
                <:item title={dgettext("admin_jobs", "Worker")}>
                  <span class="break">{@job.worker}</span>
                </:item>
                <:item title={dgettext("admin_jobs", "Attempts")}>
                  {@job.attempt} / {@job.max_attempts}
                </:item>
                <:item title={dgettext("admin_jobs", "Created")}>
                  <.timestamp at={@job.inserted_at} zone={@time_zone} format={:datetime_seconds} />
                </:item>
                <:item title={dgettext("admin_jobs", "Scheduled / next retry")}>
                  <.timestamp at={@job.scheduled_at} zone={@time_zone} format={:datetime_seconds} />
                </:item>
                <:item title={dgettext("admin_jobs", "Last attempt started")}>
                  <.timestamp at={@job.attempted_at} zone={@time_zone} format={:datetime_seconds} />
                </:item>
                <:item title={dgettext("admin_jobs", "Last execution duration")}>
                  {duration(@job.duration_ms)}
                </:item>
                <:item title={dgettext("admin_jobs", "Recorded failures")}>{@job.error_count}</:item>
              </.kv>
            </UI.panel>
            <p
              :if={
                dgettext(
                  "admin_jobs",
                  "An execution attempt failed. Raw exception details are excluded from administrative history."
                )
              }
              id="job-failure"
              class="error"
            >
              {dgettext(
                "admin_jobs",
                "An execution attempt failed. Raw exception details are excluded from administrative history."
              )}
            </p>
            <UI.panel :if={@subject} id="job-subject" title={dgettext("admin_jobs", "Related record")}>
              <.kv>
                <:item title={subject_kind(@subject.kind)}>
                  <code>{@subject.id}</code>
                </:item>
                <:item
                  :if={Map.has_key?(@subject, :status)}
                  title={dgettext("admin_jobs", "Operation state")}
                >
                  {subject_status(@subject.status)}
                </:item>
                <:item
                  :if={Map.has_key?(@subject, :finished)}
                  title={dgettext("admin_jobs", "Relocation complete")}
                >
                  {if @subject.finished,
                    do: dgettext("admin_jobs", "Complete"),
                    else: dgettext("admin_jobs", "Pending")}
                </:item>
              </.kv>
              <p :if={@subject[:vm_id]}>
                <.link navigate={~p"/machines/#{@subject.vm_id}"}>{dgettext(
                  "admin_jobs",
                  "Open machine →"
                )}</.link>
              </p>
            </UI.panel>
            <UI.panel id="job-history" title={dgettext("admin_jobs", "Execution history")}>
              <div class="table-flow">
                <table>
                  <thead>
                    <tr>
                      <th class="width-min">{dgettext("admin_jobs", "Captured")}</th>
                      <th class="width-min">{dgettext("admin_jobs", "State")}</th>
                      <th class="width-auto">{dgettext("admin_jobs", "Attempt")}</th>
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
                      <td>
                        {dgettext("admin_jobs", "attempt %{attempt} · %{count} recorded failures",
                          attempt: event.attempt,
                          count: event.error_count
                        )}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p :if={@next_events_cursor}>
                <.link
                  id="older-job-events"
                  patch={~p"/admin/jobs/#{@job.id}?#{%{events_before: @next_events_cursor}}"}
                >{dgettext("admin_jobs", "Older transitions →")}</.link>
              </p>
            </UI.panel>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  @spec subject_kind(atom()) :: String.t()
  defp subject_kind(:operation), do: dgettext("admin_jobs", "Operation")
  defp subject_kind(:relocation), do: dgettext("admin_jobs", "Relocation")
  defp subject_kind(:drain), do: dgettext("admin_jobs", "Evacuation campaign")
  defp subject_kind(_), do: dgettext("admin_jobs", "Unknown")

  @spec subject_status(atom()) :: String.t()
  defp subject_status(:pending), do: dgettext("admin_jobs", "Pending")
  defp subject_status(:acknowledged), do: dgettext("admin_jobs", "Acknowledged")
  defp subject_status(:completed), do: dgettext("admin_jobs", "Complete")
  defp subject_status(:cancelled), do: dgettext("admin_jobs", "Cancelled")
  defp subject_status(:draining), do: dgettext("admin_jobs", "Draining")
  defp subject_status(:drained), do: dgettext("admin_jobs", "Drained")
  defp subject_status(:resumed), do: dgettext("admin_jobs", "Resumed")
  defp subject_status(:retired), do: dgettext("admin_jobs", "Retired")
  defp subject_status(_), do: dgettext("admin_jobs", "Unknown")

  @spec job_tone(atom()) :: String.t() | nil
  defp job_tone(:discarded), do: "danger"
  defp job_tone(:completed), do: "success"
  defp job_tone(_), do: nil
end
