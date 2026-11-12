# Browser

The **Browser** activity (⌘8) is a tabbed WebKit browser inside Kiln that the agent can read and drive.

## Using it

- The address bar opens https for bare hosts and searches DuckDuckGo for other text; only http and https open.
- Back, forward, reload, tabs (⌘T, ⌘⌥W), find in page (⌘F).
- A **Kiln-only persistent website data store** keeps sign-ins separate from Safari; clear it from the ⋯ menu.
- Downloads are saved to the package-intake folder and offer **Analyze in Kiln**; they are never auto-imported.
- Kiln declares http and https URL handling and queues links delivered at startup (development build).
- The browser identifies itself as Safari of your Mac's version (for example `Version/27.0 Safari/605.1.15`), turns on fullscreen for page elements and allows playback without a click. A bare WebKit view sends no Safari token, which streaming and cloud-gaming sites read as an unsupported browser.

## Agent tools

`browser_open` (execute; egress-checked like `web_fetch`), `browser_read_page`, `browser_screenshot`, `browser_list_tabs` (read), `browser_click`, `browser_type` (write; approval). Page content is labelled untrusted. `browser_type` refuses password, card and one-time-code fields; password values are never read out. The agent's outline and click descriptions omit form values, but page text and screenshots can still contain sensitive information a site displays.

## Not done

Voice chat inside a page (the browser has no microphone permission prompt), popups with `window.opener` (they open as new tabs), JavaScript dialogs, HTTP authentication prompts, per-tab incognito, history and bookmarks. The agent has no tools for history or closing tabs.

## Sign-in, autofill and passkeys

WebKit handles authentication challenges and presents system credential UI where supported, but **password autofill, passkeys, third-party managers and hardware keys are not verified in Kiln**. Ordinary WKWebView passkey use needs associated domains. Apple's separate macOS browser passkey entitlement has been requested and is awaiting a decision; Kiln has not obtained it and does not promise arbitrary-site passkey support. Sign in yourself; do not paste credentials into agent prompts.

---

**Verified status.** The tools and limits come from `docs/11-CURRENT-STATE.md`, `docs/13-AGENT-CAPABILITY-MATRIX.md` and `docs/18-BROWSER-AUTHENTICATION.md`; the Browser tests are in `Tests/BrowserTests`. On 2026-11-12 a real server echoed the Safari user agent from the installed build. **Not checked:** that any cloud-gaming service then starts (it needs a sign-in; some services check more than the browser name), sign-in with real accounts, password autofill, passkeys, and the URL-handling changes in a signed build; the published preview predates them.
