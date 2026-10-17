defmodule MarshallWeb.CloneComponents do
  @moduledoc "Presentation of the persisted clone workflow; never owns lifecycle state."
  use MarshallWeb, :html

  @type phase ::
          :queued
          | :preparing
          | :stopping
          | :capturing
          | :copying
          | :publishing
          | :cleaning
          | :complete
          | :cancelling
          | :cancelled
          | :failed
  @type request :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:destination_vm_id) => String.t(),
          required(:phase) => phase(),
          required(:active) => boolean(),
          required(:failure) => String.t() | nil,
          required(:original_power_state) => :running | :stopped | nil,
          required(:source_restored_at) => DateTime.t() | nil,
          required(:published_at) => DateTime.t() | nil,
          required(:queue_position) => pos_integer() | nil,
          optional(:deferred_reason) => String.t() | nil,
          optional(:cleanup_completed_at) => DateTime.t() | nil,
          optional(atom()) => term()
        }
  @type step :: {String.t(), :done | :current | :pending}
  @type presentation :: %{
          label: String.t(),
          detail: String.t(),
          tone: :neutral | :working | :success | :warning,
          steps: [step()],
          source: String.t(),
          failure: String.t() | nil,
          open?: boolean(),
          retry?: boolean(),
          cancel?: boolean()
        }

  attr :id, :string, required: true
  attr :clone, :map, required: true

  # @cc [owner:ghuntley,label:product] clone-publication-navigation
  # Open clone MUST be rendered only with a publication receipt, including while
  # cleanup is pending. Components MUST NOT authorize or mutate clone lifecycle.
  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    assigns = assign(assigns, :progress, presentation(assigns.clone))

    ~H"""
    <article id={@id} class="clone-card" data-tone={@progress.tone} aria-labelledby={@id <> "-name"}>
      <div class="clone-card-heading">
        <div class="clone-card-name">
          <h4 id={@id <> "-name"}>{@clone.name}</h4>
        </div>
        <span class="clone-status" id={@id <> "-status"}>{@progress.label}</span>
      </div>
      <p :if={@clone.queue_position} class="clone-queue">Queue position {@clone.queue_position}</p>
      <p class="clone-detail">{@progress.detail}</p>
      <ol :if={@progress.steps != []} class="clone-steps" aria-label="Clone stages">
        <li
          :for={{label, state} <- @progress.steps}
          data-state={state}
          aria-current={state == :current && "step"}
        >
          <span class="clone-step-marker" aria-hidden="true"></span>
          <span>{label}<span class="sr-only"> — {state}</span></span>
        </li>
      </ol>
      <div class="clone-source">
        <p><strong>Source machine</strong><span>{@progress.source}</span></p>
      </div>
      <p :if={@progress.failure} class="clone-failure">{@progress.failure}</p>
      <div :if={@progress.open? || @progress.retry? || @progress.cancel?} class="clone-actions">
        <.link
          :if={@progress.open?}
          id={@id <> "-open"}
          navigate={~p"/machines/#{@clone.destination_vm_id}"}
          class="console-button primary"
        >
          Open clone <.glyph name="arrow_up_right" />
        </.link>
        <button
          :if={@progress.retry?}
          id={@id <> "-retry"}
          type="button"
          phx-click="clone-retry"
          phx-value-id={@clone.id}
          phx-disable-with="Requesting retry…"
          class="console-button"
        >
          Retry
        </button>
        <button
          :if={@progress.cancel?}
          id={@id <> "-cancel"}
          type="button"
          phx-click="clone-cancel"
          phx-value-id={@clone.id}
          phx-disable-with="Requesting cancellation…"
          class="console-button ghost"
        >
          Cancel
        </button>
      </div>
    </article>
    """
  end

  # @cc [owner:ghuntley,label:product] clone-evidence-based-progress
  # Progress MUST derive from persisted phase and receipts, never elapsed time.
  # Source restoration MUST be independent of copy progress and MUST NOT assert
  # current power state. Failure/cancellation MUST NOT fabricate completed stages.
  @spec presentation(request()) :: presentation()
  def presentation(request) do
    {label, detail, tone} = phase(request.phase)
    detail = detail_override(request) || detail
    failure = failure_message(request.failure)

    %{
      label: if(failure && request.active, do: "Needs attention", else: label),
      detail: detail,
      tone: if(failure, do: :warning, else: tone),
      steps: steps(request.phase),
      source: source(request),
      failure: failure,
      open?: not is_nil(request.published_at),
      retry?: not is_nil(request.failure) && (request.active || is_nil(request.published_at)),
      cancel?: is_nil(request.published_at) && request.phase not in [:cancelled, :complete]
    }
  end

  @spec announcement([request()]) :: String.t()
  def announcement(requests) do
    Enum.map_join(requests, " ", fn request ->
      progress = presentation(request)

      position =
        if request.queue_position, do: " Queue position #{request.queue_position}.", else: ""

      "#{request.name}: #{progress.label}.#{position} #{progress.source} #{progress.failure}"
    end)
  end

  @spec detail_override(request()) :: String.t() | nil
  defp detail_override(%{phase: :queued, deferred_reason: "transfer_busy"}),
    do: "Waiting for the host's transfer slot; another copy or move is using it."

  defp detail_override(%{phase: :queued, deferred_reason: "source_cleanup_pending"}),
    do: "Waiting for the previous copy of this machine to release its snapshot."

  defp detail_override(%{phase: :complete, cleanup_completed_at: nil}),
    do:
      "Your private copy has been created. The source snapshot is still being released; the source stays protected until then."

  defp detail_override(_), do: nil

  @spec phase(phase()) :: {String.t(), String.t(), presentation_tone()}
  @typep presentation_tone :: :neutral | :working | :success | :warning
  defp phase(:queued),
    do:
      {"Queued", "Waiting for its turn. Each copy takes a fresh snapshot when processing begins.",
       :neutral}

  defp phase(:preparing),
    do:
      {"Preparing clone", "Preparing space and checking the source before taking a snapshot.",
       :working}

  defp phase(:stopping),
    do:
      {"Stopping source for snapshot",
       "Briefly stopping the source so its disk can be captured safely.", :working}

  defp phase(:capturing),
    do:
      {"Taking snapshot",
       "Capturing the source disk. Copying begins after the snapshot is ready.", :working}

  defp phase(:copying),
    do:
      {"Copying files",
       "Creating an independent disk from the snapshot. Source recovery proceeds separately.",
       :working}

  defp phase(:publishing),
    do:
      {"Creating cloned machine", "Registering the copied disk as your private machine.",
       :working}

  defp phase(:cleaning),
    do:
      {"Finishing up",
       "The clone can be opened. Finalizing its power state and cleaning up temporary resources.",
       :working}

  defp phase(:complete),
    do:
      {"Clone complete",
       "Your private copy has been created and temporary resources have been cleaned up.",
       :success}

  defp phase(:cancelling),
    do:
      {"Cancelling clone",
       "Stopping the copy and removing temporary resources. Source recovery is tracked separately.",
       :neutral}

  defp phase(:cancelled),
    do: {"Clone cancelled", "This request has ended without publishing a clone.", :neutral}

  defp phase(:failed),
    do:
      {"Clone needs attention",
       "This request could not finish. Review the issue below and the available actions.",
       :warning}

  @spec steps(phase()) :: [step()]
  defp steps(phase) when phase in [:cancelling, :cancelled, :failed], do: []

  defp steps(phase) do
    current =
      case phase do
        :queued -> 0
        :preparing -> 1
        phase when phase in [:stopping, :capturing] -> 2
        :copying -> 3
        phase when phase in [:publishing, :cleaning] -> 4
        :complete -> 5
      end

    ["Queued", "Preparing", "Snapshot", "Copying", "Finishing"]
    |> Enum.with_index()
    |> Enum.map(fn {label, index} ->
      state =
        cond do
          index < current -> :done
          index == current -> :current
          true -> :pending
        end

      {label, state}
    end)
  end

  @spec source(request()) :: String.t()
  defp source(%{source_restored_at: at, original_power_state: :stopped}) when not is_nil(at),
    do: "Source was kept stopped, matching its state when this request began."

  defp source(%{source_restored_at: at}) when not is_nil(at),
    do: "Source returned to its original power state."

  defp source(%{failure: "source_restart_failed"}), do: "Source recovery needs attention."
  defp source(%{failure: "retry_source_restart"}), do: "Source recovery retry requested."

  defp source(%{phase: phase}) when phase in [:queued, :preparing],
    do: "Snapshot has not started."

  defp source(%{phase: :failed, original_power_state: nil}), do: "Snapshot did not start."

  defp source(%{phase: :cancelled, original_power_state: nil}),
    do: "Cancelled before the snapshot started."

  defp source(%{phase: :stopping}), do: "Waiting for the source to stop."

  defp source(%{original_power_state: :stopped}),
    do: "Source was stopped when this request began."

  defp source(%{phase: :capturing}), do: "Source recovery follows the snapshot."
  defp source(_request), do: "Waiting for source recovery confirmation."

  @spec failure_message(String.t() | nil) :: String.t() | nil
  defp failure_message(nil), do: nil
  defp failure_message("retry_source_restart"), do: nil

  defp failure_message("source_restart_failed"),
    do: "The source could not restart. Retry to request source recovery."

  defp failure_message("destination_start_failed"),
    do: "The clone could not start. Open it to review its status and power controls."

  defp failure_message("insufficient_capacity"),
    do: "There is not enough capacity for this copy. Retry when space is available."

  defp failure_message(reason)
       when reason in ["vm_busy", "workload_not_stable", "placement_changed"],
       do: "The source was busy or changed before cloning began. Retry when it is ready."

  defp failure_message("source_unavailable"),
    do: "The source host is unavailable. Retry once it is available."

  defp failure_message("transfer_busy"),
    do: "Another copy or move is using this host's transfer slot. Retry when it finishes."

  defp failure_message("source_cleanup_pending"),
    do: "The previous copy of this machine is still releasing its snapshot. Retry shortly."

  defp failure_message("forbidden"),
    do: "Permission to clone this machine is no longer available."

  defp failure_message("vm_deleted"),
    do: "The source machine was deleted before this request began."

  defp failure_message(reason) do
    case Marshall.Compute.CloneFailure.parse(reason) do
      {:ok, kind, host_reason} ->
        "Step #{kind} is waiting on the host: #{host_reason_message(host_reason)}"

      :error ->
        "The request encountered a problem. Use the available actions to recover or cancel it."
    end
  end

  @spec host_reason_message(Marshall.Compute.CloneFailure.reason()) :: String.t()
  defp host_reason_message(:storage_busy),
    do: "the storage pool is busy; the host retries automatically."

  defp host_reason_message(:execution_unavailable),
    do: "the machine is mid-operation; the host retries automatically."

  defp host_reason_message(:source_authority_unconfirmed),
    do: "the source changed state; it continues once the source settles."

  defp host_reason_message(:snapshot_unconfirmed),
    do: "the source snapshot could not be prepared or released yet."

  defp host_reason_message(:mount_unconfirmed),
    do: "a snapshot mount could not be released yet."

  defp host_reason_message(:copy_unconfirmed),
    do: "the disk copy did not finish; it resumes automatically."

  defp host_reason_message(reason) when reason in [:stream_unconfirmed, :receive_unconfirmed],
    do: "the transfer stream was interrupted; it resumes automatically."

  defp host_reason_message(reason) when reason in [:lease_unconfirmed, :permit_unconfirmed],
    do: "the transfer permit lapsed; it is renewed automatically."

  defp host_reason_message(reason) when reason in [:key_unconfirmed, :ssh_unconfirmed],
    do: "the hosts could not connect; the host retries automatically."

  defp host_reason_message(reason)
       when reason in [:export_revocation_unconfirmed, :import_cleanup_unconfirmed],
       do: "cleanup on the host did not finish yet."

  defp host_reason_message(:disk_unconfirmed),
    do: "the copied disk could not be prepared yet."

  defp host_reason_message(_),
    do: "the host could not confirm the step yet."
end
