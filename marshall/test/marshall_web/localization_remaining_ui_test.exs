defmodule MarshallWeb.LocalizationRemainingUITest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias MarshallWeb.{CloneComponents, WorkspaceComponents}

  # @cc [owner:ghuntley,label:product;verification] localized-state-preserves-machine-contracts
  # Localized human labels MUST leave pin payloads and clone stage data states
  # unchanged, and mixed-script machine names MUST remain escaped and isolated in RTL.
  test "Japanese and Arabic pin labels preserve state, payload and untrusted names" do
    name = "alice-علي-<123>"

    for locale <- ["ja", "ar"], pinned <- [false, true] do
      Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
        source = if pinned, do: "Unpin", else: "Pin"
        expected = Gettext.dgettext(MarshallWeb.Gettext, "terminal", source)
        refute expected == source

        html =
          render_component(&WorkspaceComponents.pin_toggle/1,
            id: "pin-localized",
            vm: %{
              id: "machine-123",
              name: name,
              pinned: pinned,
              desired_state: :running,
              observed_state: :running
            }
          )

        document = LazyHTML.from_fragment(html)
        assert LazyHTML.query(document, "button") |> LazyHTML.text() |> String.trim() == expected
        assert document |> LazyHTML.query("button") |> LazyHTML.attribute("aria-pressed") == [to_string(pinned)]
        assert document |> LazyHTML.query("button") |> LazyHTML.attribute("phx-value-id") == ["machine-123"]
        [label] = document |> LazyHTML.query("button") |> LazyHTML.attribute("aria-label")
        assert label =~ name
        if locale == "ar", do: assert(label =~ "\u2068#{name}\u2069")
        refute html =~ "<123>"
      end)
    end
  end

  test "Japanese and Arabic clone host failures and accessible stage labels translate" do
    sources = [
      {"storage_busy", "the storage pool is busy; the host retries automatically."},
      {"execution_unavailable", "the machine is mid-operation; the host retries automatically."},
      {"source_authority_unconfirmed",
       "the source changed state; it continues once the source settles."},
      {"snapshot_unconfirmed", "the source snapshot could not be prepared or released yet."},
      {"mount_unconfirmed", "a snapshot mount could not be released yet."},
      {"copy_unconfirmed", "the disk copy did not finish; it resumes automatically."},
      {"stream_unconfirmed", "the transfer stream was interrupted; it resumes automatically."},
      {"lease_unconfirmed", "the transfer permit lapsed; it is renewed automatically."},
      {"ssh_unconfirmed", "the hosts could not connect; the host retries automatically."},
      {"import_cleanup_unconfirmed", "cleanup on the host did not finish yet."},
      {"disk_unconfirmed", "the copied disk could not be prepared yet."},
      {"effect_unconfirmed", "the host could not confirm the step yet."}
    ]

    for locale <- ["ja", "ar"] do
      Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
        for {reason, source} <- sources do
          expected = Gettext.dgettext(MarshallWeb.Gettext, "machines", source)
          refute expected == source
          progress = CloneComponents.presentation(clone("copy_" <> reason))
          assert progress.failure =~ expected
          refute progress.failure =~ source
        end

        html = render_component(&CloneComponents.card/1, id: "clone-localized", clone: clone(nil))
        document = LazyHTML.from_fragment(html)

        for node <- LazyHTML.query(document, "li[data-state]") do
          [state] = node |> LazyHTML.attribute("data-state")
          source = %{"done" => "Done", "current" => "Current", "pending" => "Pending"}[state]
          expected = Gettext.dgettext(MarshallWeb.Gettext, "machines", source)
          refute expected == source
          assert LazyHTML.query(node, ".sr-only") |> LazyHTML.text() == " — " <> expected
        end
      end)
    end
  end

  @spec clone(String.t() | nil) :: CloneComponents.request()
  defp clone(failure) do
    %{
      id: "clone-123",
      name: "copy",
      destination_vm_id: "machine-123",
      phase: :copying,
      active: true,
      failure: failure,
      original_power_state: :running,
      source_restored_at: nil,
      published_at: nil,
      queue_position: nil
    }
  end
end
