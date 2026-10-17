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
         socket |> put_flash(:info, "Team #{team.name} created.") |> refresh() |> select(team.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not create this team.")}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.teams, &(&1.id == id)) do
      {:noreply, select(socket, id)}
    else
      {:noreply, put_flash(socket, :error, "Invalid request.")}
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
        {:noreply, socket |> put_flash(:info, "Membership updated.") |> refresh_members()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "Could not update this membership.") |> refresh_members()}
    end
  end

  def handle_event("transfer_offer", %{"transfer" => %{"email" => email}}, socket) do
    case Teams.Coordinator.offer(socket.assigns.selected, email, socket.assigns.current_user) do
      {:ok, _transfer} ->
        {:noreply,
         socket
         |> assign(transfer_form: transfer_form())
         |> put_flash(:info, "Ownership offer sent.")
         |> refresh_members()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not offer ownership.") |> refresh_members()}
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
        {:noreply, socket |> put_flash(:info, "Ownership offer updated.") |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update this ownership offer.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid request.")}

  defp refresh(socket) do
    case Teams.list_teams(%{}, actor: socket.assigns.current_user) do
      {:ok, teams} ->
        selected = socket.assigns.selected || (List.first(teams) && List.first(teams).id)
        socket |> assign(teams: teams, selected: selected) |> refresh_members()

      {:error, _} ->
        socket
        |> assign(teams: [], members: [], transfer: nil)
        |> put_flash(:error, "Teams are temporarily unavailable.")
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
    <Layouts.app flash={@flash} current_scope={%{user: @current_user}} compute={true} active="teams">
      <section id="teams-page" class="stack">
        <UI.heading
          title="Teams"
          subtitle="Share machines and integrations with the people you work with. Owners appoint admins, admins manage members."
        />
        <p :if={@teams == []} class="empty-state">
          You are not in a team yet. Create one below, or ask a team admin to add you.
        </p>
        <div :if={@teams != []} id="teams" class="stack">
          <nav class="machine-tabs" aria-label="Your teams">
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
                  You are {article(selected_team(assigns).role)} {selected_team(assigns).role} · {length(
                    @members
                  )} {if length(@members) == 1,
                    do: "member",
                    else: "members"}
                </p>
              </div>
            </header>
            <UI.panel id="team-members" title="Members">
              <div class="table-flow">
                <table>
                  <thead>
                    <tr>
                      <th class="width-min">Member</th>
                      <th class="width-min">Role</th>
                      <th class="width-auto">Can</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={member <- @members}>
                      <td class="break">{member.email}</td>
                      <td><span class="status-label">{member.role}</span></td>
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
                <h3>Add, change or remove a member</h3>
                <div class="grid">
                  <.input
                    field={@member_form[:email]}
                    label="Registered email"
                    placeholder="teammate@example.test"
                  />
                  <.input
                    field={@member_form[:role]}
                    label="Role"
                    type="select"
                    options={[{"Admin", "admin"}, {"Member", "member"}, {"Remove", "removed"}]}
                  />
                </div>
                <div class="row actions">
                  <button type="submit" class="console-button primary">Save member</button>
                </div>
              </.form>
            </UI.panel>
            <UI.panel id="team-ownership" title="Ownership">
              <p class="muted">
                A team has one owner. Ownership moves only when the person it is offered to
                accepts; the previous owner becomes an admin.
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
                  label="Offer ownership to"
                  placeholder="teammate@example.test"
                />
                <button type="submit" class="console-button">Offer ownership</button>
              </.form>
              <div :if={@transfer} id="pending-transfer" class="stack">
                <.kv>
                  <:item title="Offered by">{@transfer.from_email}</:item>
                  <:item title="Offered to">{@transfer.to_email}</:item>
                  <:item title="Status"><span class="status-label">pending</span></:item>
                </.kv>
                <p class="sr-only">
                  Ownership offered by {@transfer.from_email} to {@transfer.to_email}.
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
                    Accept ownership
                  </button>
                  <button
                    :if={@transfer.to_user_id == @current_user.id}
                    id="decline-transfer"
                    phx-click="transfer"
                    phx-value-action="decline"
                    phx-value-id={@transfer.id}
                    class="console-button"
                  >
                    Decline
                  </button>
                  <button
                    :if={@transfer.from_user_id == @current_user.id}
                    id="cancel-transfer"
                    phx-click="transfer"
                    phx-value-action="cancel"
                    phx-value-id={@transfer.id}
                    class="console-button"
                  >
                    Cancel offer
                  </button>
                </div>
              </div>
              <p :if={!@transfer && selected_team(assigns).role != :owner} class="muted">
                No pending ownership offer.
              </p>
            </UI.panel>
          </div>
        </div>
        <.form for={@form} id="team-form" phx-submit="create" class="panel stack">
          <h2>Create a team</h2>
          <p class="muted">You become its owner and can add members straight away.</p>
          <.input field={@form[:name]} label="Team name" placeholder="platform" />
          <div class="row actions">
            <button type="submit" class="console-button primary">Create team</button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @spec article(atom()) :: String.t()
  defp article(:owner), do: "the"
  defp article(:admin), do: "an"
  defp article(_), do: "a"

  @spec role_summary(atom()) :: String.t()
  defp role_summary(:owner), do: "Everything, including appointing admins and offering ownership."
  defp role_summary(:admin), do: "Manage members and team machines."
  defp role_summary(:member), do: "Use team machines and integrations."
  defp role_summary(_), do: ""
end
