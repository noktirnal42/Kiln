# Devices

The **Devices** activity (⌘9) lists every Apple simulator and Android emulator or attached device, boots and shuts them down, and shows the selected screen. The agent's and MCP server's `device_*` tools share one service with the view, so they cannot disagree.

| Operation | Apple simulator (`xcrun simctl`) | Android (`adb`, `emulator`) |
|---|---|---|
| List | yes (unavailable runtimes shown greyed with the reason) | yes |
| Boot and shut down | yes | yes (waits for boot to complete) |
| Screenshot | yes | yes |
| Install and launch | yes | yes |
| Open a URL | yes | yes |
| Record video, logs | yes | yes |
| Tap, swipe, type, key | **not available**: `simctl` has no input commands | yes |

The view refreshes the screenshot every 1.5 s while a booted device is selected. On Android, clicking taps and dragging swipes.

## Honest gaps

- **Apple input** cannot be injected through `simctl`; `device_input` on an Apple simulator returns an error that says so. Moving around is possible with `device_open_url` and `device_launch`.
- **Windows and Linux guests** are a design only.
- Kiln never downloads Xcode, SDKs, simulator runtimes or system images. A missing platform shows a Setup needed card with what to install.
- `adb devices` starts the adb server if it is not running, and a booted emulator is a child process of Kiln, so it ends when Kiln quits.

## Tools and permission levels

- **read:** `device_list`, `device_status`, `device_screenshot`, `device_logs` (screenshots go to `Application Support/Kiln/Devices/Captures`)
- **execute:** `device_boot`, `device_shutdown`, `device_install`, `device_launch`
- **write:** `device_open_url`, `device_input`, `device_record_video`

Only the Workstation Agent profile enables them; write and execute calls open the approval sheet, and arguments reaching an Android shell are validated or quoted.

---

**Verified status.** The tables follow `docs/16-DEVICES.md`; the Devices tests are in `Tests/DevicesTests`. **Not checked:** Android emulators and boot timing on a fresh Mac in this pass (needs an installed Android SDK), and any Windows or Linux guest.
