# Browser authentication status

Kiln's Browser uses `WKWebView` and a persistent Kiln-specific website data store. WebKit handles
website authentication challenges and presents system credential UI where supported. This is not
evidence that arbitrary-site passwords, passkeys, third-party managers, or hardware keys work in
Kiln: each requires testing with the signed shipping build and real accounts. No credential contents
should be copied into agent prompts or logs.

The development build declares HTTP and HTTPS URL handling, queues links delivered during startup,
and opens on the Browser activity with an address/search field. These changes have not yet been
verified in a signed build or approved by Apple. The current published preview predates them.

Apple documents that ordinary WKWebView passkey use requires associated domains. Its separate
[browser public-key credential entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
requires an organization account holder to request approval and satisfy Apple's browser criteria.
Kiln has not established eligibility or obtained that entitlement. Do not add it to the shipping
signature or promise arbitrary-site passkey support until Apple grants it and the flow is verified.
See also [Apple's browser authentication guidance](https://developer.apple.com/documentation/authenticationservices/password-use-in-web-browsers)
and [passkey guidance](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys).

The [Apple request form](https://developer.apple.com/contact/request/macos-browsers-passkeys/)
asks for app name, bundle ID, whether the app is a macOS browser and supports WebAuthn, planned
iCloud Keychain integration, and a link to a downloadable browser build. It also requires offering
both sign-in using existing passkeys and saving new ones once the entitlement is assigned. Prepare a
browser-enabled signed evaluation build and validate its behavior before asserting support or
submitting. The source project currently uses `com.kiln.app`, which Apple reported unavailable for
registration. A new App ID, `dev.noktirnal.kiln`, has been registered and a request submitted for it.
The project and release migration to that identity are not complete; preferences, Keychain, signing,
installed-app behavior, and privacy permissions need verification before distributing that build.

The agent's outline and click descriptions omit form values. Page text and screenshots can still
contain sensitive information displayed by a site; users should treat agent browsing as access to
the visible page, and should sign in themselves. Test password autofill, passkey registration and
sign-in, third-party providers, cancellation and browser restart before making support claims.
