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
    locale =
      Marshall.Localization.normalize(Gettext.get_locale(MarshallWeb.Gettext)) ||
        Marshall.Localization.default()

    assigns = %{
      message: status_message(template),
      locale: locale,
      direction: Marshall.Localization.direction(locale),
      retry?: template == "500.html" and not Marshall.Repo.answers?(),
      cat: " /\\_/\\\n( -.- )\n > ^ <"
    }

    ~H"""
    <!DOCTYPE html>
    <html lang={@locale} dir={@direction}>
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
          <main id="main-content" class="error-page">
            <pre aria-hidden="true">{@cat}</pre>
            <h1>{@message}</h1>
            <p :if={@retry?}>
              {dgettext(
                "errors",
                "Overalls is briefly unavailable. This page will retry automatically."
              )}
            </p>
            <p :if={!@retry?}>
              {dgettext(
                "errors",
                "We couldn’t open this page. Head back to your workspace, or try again in a moment."
              )}
            </p>
            <.link href={~p"/"} class="console-button primary">{dgettext("errors", "Back to Overalls")}</.link>
          </main>
        </div>
      </body>
    </html>
    """
  end

  # @cc [owner:ghuntley,label:product;verification] error-page-localized-status
  # Every standard HTTP error heading known by pinned Plug MUST have a literal
  # errors-domain identity. Unknown templates MUST use the standard server-error
  # heading without exposing exception details or request data.
  @spec status_message(String.t()) :: String.t()
  defp status_message(template) do
    case Phoenix.Controller.status_message_from_template(template) do
      "Bad Request" -> dgettext("errors", "Bad Request")
      "Unauthorized" -> dgettext("errors", "Unauthorized")
      "Payment Required" -> dgettext("errors", "Payment Required")
      "Forbidden" -> dgettext("errors", "Forbidden")
      "Not Found" -> dgettext("errors", "Not Found")
      "Method Not Allowed" -> dgettext("errors", "Method Not Allowed")
      "Not Acceptable" -> dgettext("errors", "Not Acceptable")
      "Proxy Authentication Required" -> dgettext("errors", "Proxy Authentication Required")
      "Request Timeout" -> dgettext("errors", "Request Timeout")
      "Conflict" -> dgettext("errors", "Conflict")
      "Gone" -> dgettext("errors", "Gone")
      "Length Required" -> dgettext("errors", "Length Required")
      "Precondition Failed" -> dgettext("errors", "Precondition Failed")
      "Request Entity Too Large" -> dgettext("errors", "Request Entity Too Large")
      "Request-URI Too Long" -> dgettext("errors", "Request-URI Too Long")
      "Unsupported Media Type" -> dgettext("errors", "Unsupported Media Type")
      "Requested Range Not Satisfiable" -> dgettext("errors", "Requested Range Not Satisfiable")
      "Expectation Failed" -> dgettext("errors", "Expectation Failed")
      "I'm a teapot" -> dgettext("errors", "I'm a teapot")
      "Misdirected Request" -> dgettext("errors", "Misdirected Request")
      "Unprocessable Content" -> dgettext("errors", "Unprocessable Content")
      "Locked" -> dgettext("errors", "Locked")
      "Failed Dependency" -> dgettext("errors", "Failed Dependency")
      "Too Early" -> dgettext("errors", "Too Early")
      "Upgrade Required" -> dgettext("errors", "Upgrade Required")
      "Precondition Required" -> dgettext("errors", "Precondition Required")
      "Too Many Requests" -> dgettext("errors", "Too Many Requests")
      "Request Header Fields Too Large" -> dgettext("errors", "Request Header Fields Too Large")
      "Unavailable For Legal Reasons" -> dgettext("errors", "Unavailable For Legal Reasons")
      "Internal Server Error" -> dgettext("errors", "Internal Server Error")
      "Not Implemented" -> dgettext("errors", "Not Implemented")
      "Bad Gateway" -> dgettext("errors", "Bad Gateway")
      "Service Unavailable" -> dgettext("errors", "Service Unavailable")
      "Gateway Timeout" -> dgettext("errors", "Gateway Timeout")
      "HTTP Version Not Supported" -> dgettext("errors", "HTTP Version Not Supported")
      "Variant Also Negotiates" -> dgettext("errors", "Variant Also Negotiates")
      "Insufficient Storage" -> dgettext("errors", "Insufficient Storage")
      "Loop Detected" -> dgettext("errors", "Loop Detected")
      "Not Extended" -> dgettext("errors", "Not Extended")
      "Network Authentication Required" -> dgettext("errors", "Network Authentication Required")
      _ -> dgettext("errors", "Internal Server Error")
    end
  end
end
