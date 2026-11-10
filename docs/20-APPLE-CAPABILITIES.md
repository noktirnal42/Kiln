# Apple platform capabilities

Status as of 2026-11-09. Apple Developer settings and app behavior are separate: an enabled App ID
capability does not by itself implement, sign, or verify a feature.

The registered App ID `dev.noktirnal.kiln` has iCloud (CloudKit), Push Notifications, Maps, and
Private Cloud Compute selected. Its iCloud container is `iCloud.dev.noktirnal.kiln`. The current
source project and released preview still use `com.kiln.app`; the identity migration and provisioning
are not complete. No CloudKit sync, push delivery, or Maps feature has been verified in this build.

The in-development `ApplePrivateCloudProvider` is a separate, explicitly selected provider from the
on-device model. It requires macOS 27 and checks system availability. It has not yet been tested
with an entitlement-bearing signed build or a real Private Cloud Compute request. Apple lists
Small Business Program enrollment, download thresholds and a managed entitlement as eligibility
conditions, and describes distribution through the App Store and testing through TestFlight or
ad hoc distribution. Do not assume the existing Developer ID distribution qualifies. See
[Apple's eligibility page](https://developer.apple.com/private-cloud-compute/).

The macOS browser passkey entitlement has been requested and is awaiting Apple's decision. Browser
credential and passkey testing is tracked in [browser authentication](18-BROWSER-AUTHENTICATION.md).
Apple's Foundation Models adapter request page says requests are closed and that the adapter API is
incompatible with macOS 27 and later; this is separate from the Private Cloud Compute provider.
