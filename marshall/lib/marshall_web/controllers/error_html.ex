defmodule MarshallWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use MarshallWeb, :html

  # @cc [owner:ghuntley,label:security;recovery] error-page-public-message
  # Error pages MUST render only the standard status message and fixed recovery
  # guidance. Request paths, exception details and credentials MUST NOT appear.
  # A server error while the database does not answer is inconclusive
  # (ADR-0140): the page retries itself instead of stranding the browser.
  @spec render(String.t(), map()) :: Phoenix.LiveView.Rendered.t()
  def render(template, _assigns) do
    assigns = %{
      message:
        Gettext.gettext(
          MarshallWeb.Gettext,
          Phoenix.Controller.status_message_from_template(template)
        ),
      retry?: template == "500.html" and not Marshall.Repo.answers?(),
      cat: " /\\_/\\\n( -.- )\n > ^ <"
    }

    ~H"""
    <!DOCTYPE html>
    <html lang={assigns[:locale] || "en"} dir={assigns[:direction] || :ltr}>
      <head>
        <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta :if={@retry?} http-equiv="refresh" content="3" />
        <title>{@message} · Overalls</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
        <link rel="icon" href={~p"/images/overalls.svg"} />
        <script defer src={~p"/assets/js/app.js"}>
        </script>
      </head>
      <body>
        <div class="public-page">
          <Layouts.console_header />
          <main id="main-content" class="error-page">
            <pre aria-hidden="true">{@cat}</pre>
            <h1>{@message}</h1>
            <p :if={@retry?}>
              {gettext("Overalls is briefly unavailable. This page will retry automatically.")}
            </p>
            <p :if={!@retry?}>
              {gettext(
                "We couldn’t open this page. Head back to your workspace, or try again in a moment."
              )}
            </p>
            <.link href={~p"/"} class="console-button primary">{gettext("Back to Overalls")}</.link>
          </main>
        </div>
      </body>
    </html>
    """
  end
end
