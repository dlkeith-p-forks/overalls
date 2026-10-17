# Browser extension

Open a GitHub, GitLab, Codeberg or Bitbucket Cloud repository in Overalls with a
single toolbar click. The extension carries only the provider origin and path to
Overalls, so you can move from a repository page to a machine without copying a
URL by hand.

## Install the developer archive

These archives are unsigned and are served by the Overalls deployment. Download
the archive for your browser, then follow its developer-install flow:

- [Download for Chrome or Chromium](/bin/chrome.zip): extract the ZIP, open
  `chrome://extensions`, enable **Developer mode**, and choose **Load unpacked**.
- [Download for Firefox](/bin/firefox.xpi): open `about:debugging`, choose
  **This Firefox**, then **Load Temporary Add-on** and select the downloaded XPI.

Firefox temporary add-ons are removed when Firefox closes. Permanent Firefox
installation requires Mozilla signing or an explicitly managed browser policy.
Overalls does not currently publish either archive to a browser store.

## Configure and open a repository

1. Open the extension's settings from the browser toolbar. If it is already
   configured, use the toolbar's context menu and choose **Configure Overalls
   server…** to change the server.
2. Enter the HTTPS origin of this Overalls server. HTTP is supported only for
   loopback development. The server origin is always selected explicitly; the
   extension never guesses it from a page.
3. Visit a supported repository page and click the Overalls toolbar button.

On a supported repository page, clicking an unconfigured toolbar button opens
settings. Unsupported hosts show an **Unsupported page** state and do not send a
URL. Marshall checks the launch request again before staging it and may require
you to sign in.

When the extension has been configured for this exact Overalls origin and the
browser has granted site access, it marks the open Overalls page as installed.
That local marker hides setup prompts on the home page; it does not sign you in,
grant access to machines, or change launch authorization. If site access is
withdrawn, configuration is missing, or detection is unavailable, setup remains
visible.

## Privacy and availability

The extension opens Overalls with a source URL only after an explicit toolbar
click on the four supported HTTPS provider hosts. It sends the provider origin
and path, strips query parameters and fragments, and never collects page
contents, credentials, history or telemetry.

The Overalls operator chooses whether these immutable archives are available. If
the deployment has disabled its browser extension package, the download links return an unavailable response.
See the browser distribution notes for package and build details.
