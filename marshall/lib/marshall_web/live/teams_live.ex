defmodule MarshallWeb.TeamsLive do
  use MarshallWeb, :live_view

  alias Marshall.Teams
  on_mount {MarshallWeb.AuthenticationPrivacy, :default}
  on_mount {MarshallWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(teams: [], members: [], transfer: nil, selected: nil)
     |> reset_form()
     |> refresh()}
  end

  @impl true
  def handle_event("create", %{"team" => params}, socket) when is_map(params) do
    result =
      Teams.create_team(
        %{name: params["name"], idempotency_key: "web:" <> Ash.UUID.generate()},
        actor: socket.assigns.current_user
      )

    socket = reset_form(socket)

    case result do
      {:ok, team} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("teams", "Team %{value1} created.", value1: team.name))
         |> refresh()
         |> select(team.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, dgettext("teams", "Could not create this team."))}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.teams, &(&1.id == id)) do
      {:noreply, select(socket, id)}
    else
      {:noreply, put_flash(socket, :error, dgettext("teams", "Invalid request."))}
    end
  end

  def handle_event("member", %{"member" => params}, socket) when is_map(params) do
    role =
      case params["role"] do
        "admin" -> :admin
        "member" -> :member
        _ -> :removed
      end

    result =
      Teams.set_team_member(
        %{
          team_id: socket.assigns.selected,
          email: params["email"],
          role: role,
          idempotency_key: "web:" <> Ash.UUID.generate()
        },
        actor: socket.assigns.current_user
      )

    socket = reset_form(socket)

    case result do
      {:ok, _member} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("teams", "Membership updated.")) |> refresh_members()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("teams", "Could not update this membership."))
         |> refresh_members()}
    end
  end

  def handle_event("transfer_offer", %{"transfer" => %{"email" => email}}, socket) do
    case Teams.Coordinator.offer(socket.assigns.selected, email, socket.assigns.current_user) do
      {:ok, _transfer} ->
        {:noreply,
         socket
         |> assign(transfer_form: transfer_form())
         |> put_flash(:info, dgettext("teams", "Ownership offer sent."))
         |> refresh_members()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("teams", "Could not offer ownership."))
         |> refresh_members()}
    end
  end

  def handle_event("transfer", %{"action" => action, "id" => id}, socket) do
    result =
      case action do
        "accept" -> Teams.Coordinator.accept(id, socket.assigns.current_user)
        "decline" -> Teams.Coordinator.decline(id, socket.assigns.current_user)
        "cancel" -> Teams.Coordinator.cancel(id, socket.assigns.current_user)
        _ -> {:error, :invalid_request}
      end

    case result do
      {:ok, _transfer} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("teams", "Ownership offer updated.")) |> refresh()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("teams", "Could not update this ownership offer."))}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, dgettext("teams", "Invalid request."))}

  defp refresh(socket) do
    case Teams.list_teams(%{}, actor: socket.assigns.current_user) do
      {:ok, teams} ->
        selected = socket.assigns.selected || (List.first(teams) && List.first(teams).id)
        socket |> assign(teams: teams, selected: selected) |> refresh_members()

      {:error, _} ->
        socket
        |> assign(teams: [], members: [], transfer: nil)
        |> put_flash(:error, dgettext("teams", "Teams are temporarily unavailable."))
    end
  end

  defp refresh_members(socket) do
    id = socket.assigns.selected

    {members, transfer} =
      if id do
        with {:ok, members} <-
               Teams.list_team_members(%{team_id: id}, actor: socket.assigns.current_user),
             {:ok, transfers} <-
               Teams.list_team_transfers(%{team_id: id}, actor: socket.assigns.current_user) do
          {members, List.first(transfers)}
        else
          _ -> {[], nil}
        end
      else
        {[], nil}
      end

    assign(socket, members: members, transfer: transfer)
  end

  defp select(socket, id), do: socket |> assign(selected: id) |> refresh_members()

  defp reset_form(socket),
    do:
      assign(
        socket,
        form: to_form(%{"name" => "", "email" => "", "role" => "member"}, as: :team),
        member_form: to_form(%{"email" => "", "role" => "member"}, as: :member),
        transfer_form: transfer_form()
      )

  defp transfer_form, do: to_form(%{"email" => ""}, as: :transfer)

  defp selected_team(assigns), do: Enum.find(assigns.teams, &(&1.id == assigns.selected))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{user: @current_user}}
      time_zone={@time_zone}
      now={@now}
      compute={true}
      active="teams"
    >
      <section id="teams-page" class="stack">
        <UI.heading
          title={dgettext("teams", "Teams")}
          subtitle={
            dgettext(
              "teams",
              "Share machines and integrations with the people you work with. Owners appoint admins, admins manage members."
            )
          }
        />
        <p :if={@teams == []} class="empty-state">
          {dgettext(
            "teams",
            "You are not in a team yet. Create one below, or ask a team admin to add you."
          )}
        </p>
        <div :if={@teams != []} id="teams" class="stack">
          <nav class="machine-tabs" aria-label={dgettext("teams", "Your teams")}>
            <button
              :for={team <- @teams}
              phx-click="select"
              phx-value-id={team.id}
              aria-pressed={team.id == @selected}
              class="team-choice"
            >{team.name}</button>
          </nav>
          <div :if={@selected} class="stack">
            <header class="page-heading ident">
              <div>
                <h1>{selected_team(assigns).name}</h1>
                <p>
                  {dgettext("teams", "Your role: %{role}",
                    role: role_label(selected_team(assigns).role)
                  )} · {dngettext(
                    "teams",
                    "%{count} member",
                    "%{count} members",
                    length(@members)
                  )}
                </p>
              </div>
            </header>
            <UI.panel id="team-members" title={dgettext("teams", "Members")}>
              <div class="table-flow">
                <table>
                  <thead>
                    <tr>
                      <th class="width-min">{dgettext("teams", "Member")}</th>
                      <th class="width-min">{dgettext("teams", "Role")}</th>
                      <th class="width-auto">{dgettext("teams", "Can")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={member <- @members}>
                      <td class="break">
                        <.person
                          id={"team-member-#{member.user_id}"}
                          email={member.email}
                          time_zone={member.time_zone}
                          viewer_zone={@time_zone}
                          now={@now}
                        />
                      </td>
                      <td><span class="status-label">{role_label(member.role)}</span></td>
                      <td class="muted">{role_summary(member.role)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <.form
                :if={selected_team(assigns).role in [:owner, :admin]}
                for={@member_form}
                id="member-form"
                phx-submit="member"
                class="stack"
              >
                <h3>{dgettext("teams", "Add, change or remove a member")}</h3>
                <div class="grid">
                  <.input
                    field={@member_form[:email]}
                    label={dgettext("teams", "Registered email")}
                    placeholder={dgettext("teams", "teammate@example.test")}
                  />
                  <.input
                    field={@member_form[:role]}
                    label={dgettext("teams", "Role")}
                    type="select"
                    options={[
                      {dgettext("teams", "Admin"), "admin"},
                      {dgettext("teams", "Member"), "member"},
                      {dgettext("teams", "Remove"), "removed"}
                    ]}
                  />
                </div>
                <div class="row actions">
                  <button type="submit" class="console-button primary">{dgettext(
                    "teams",
                    "Save member"
                  )}</button>
                </div>
              </.form>
            </UI.panel>
            <UI.panel id="team-ownership" title={dgettext("teams", "Ownership")}>
              <p class="muted">
                {dgettext(
                  "teams",
                  "A team has one owner. Ownership moves only when the person it is offered to accepts; the previous owner becomes an admin."
                )}
              </p>
              <.form
                :if={selected_team(assigns).role == :owner && !@transfer}
                for={@transfer_form}
                id="transfer-offer-form"
                phx-submit="transfer_offer"
                class="field-row"
              >
                <.input
                  field={@transfer_form[:email]}
                  label={dgettext("teams", "Offer ownership to")}
                  placeholder={dgettext("teams", "teammate@example.test")}
                />
                <button type="submit" class="console-button">{dgettext("teams", "Offer ownership")}</button>
              </.form>
              <div :if={@transfer} id="pending-transfer" class="stack">
                <.kv>
                  <:item title={dgettext("teams", "Offered by")}>
                    <.person
                      id="transfer-from"
                      email={@transfer.from_email}
                      time_zone={@transfer.from_time_zone}
                      viewer_zone={@time_zone}
                      now={@now}
                    />
                  </:item>
                  <:item title={dgettext("teams", "Offered to")}>
                    <.person
                      id="transfer-to"
                      email={@transfer.to_email}
                      time_zone={@transfer.to_time_zone}
                      viewer_zone={@time_zone}
                      now={@now}
                    />
                  </:item>
                  <:item title={dgettext("teams", "Status")}>
                    <span class="status-label">{dgettext("teams", "pending")}</span>
                  </:item>
                </.kv>
                <p class="sr-only">
                  {dgettext("teams", "Ownership offered by %{value1} to %{value2}.",
                    value1: @transfer.from_email,
                    value2: @transfer.to_email
                  )}
                </p>
                <div class="row actions">
                  <button
                    :if={@transfer.to_user_id == @current_user.id}
                    id="accept-transfer"
                    phx-click="transfer"
                    phx-value-action="accept"
                    phx-value-id={@transfer.id}
                    class="console-button primary"
                  >
                    {dgettext("teams", "Accept ownership")}
                  </button>
                  <button
                    :if={@transfer.to_user_id == @current_user.id}
                    id="decline-transfer"
                    phx-click="transfer"
                    phx-value-action="decline"
                    phx-value-id={@transfer.id}
                    class="console-button"
                  >
                    {dgettext("teams", "Decline")}
                  </button>
                  <button
                    :if={@transfer.from_user_id == @current_user.id}
                    id="cancel-transfer"
                    phx-click="transfer"
                    phx-value-action="cancel"
                    phx-value-id={@transfer.id}
                    class="console-button"
                  >
                    {dgettext("teams", "Cancel offer")}
                  </button>
                </div>
              </div>
              <p :if={!@transfer && selected_team(assigns).role != :owner} class="muted">
                {dgettext("teams", "No pending ownership offer.")}
              </p>
            </UI.panel>
          </div>
        </div>
        <.form for={@form} id="team-form" phx-submit="create" class="panel stack">
          <h2>{dgettext("teams", "Create a team")}</h2>
          <p class="muted">
            {dgettext("teams", "You become its owner and can add members straight away.")}
          </p>
          <.input
            field={@form[:name]}
            label={dgettext("teams", "Team name")}
            placeholder={dgettext("teams", "platform")}
          />
          <div class="row actions">
            <button type="submit" class="console-button primary">{dgettext("teams", "Create team")}</button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @spec role_label(atom()) :: String.t()
  defp role_label(:owner), do: dgettext("teams", "Owner")
  defp role_label(:admin), do: dgettext("teams", "Administrator")
  defp role_label(_), do: dgettext("teams", "Member")

  @spec role_summary(atom()) :: String.t()
  defp role_summary(:owner),
    do: dgettext("teams", "Everything, including appointing admins and offering ownership.")

  defp role_summary(:admin), do: dgettext("teams", "Manage members and team machines.")
  defp role_summary(:member), do: dgettext("teams", "Use team machines and integrations.")
  defp role_summary(_), do: ""
end
