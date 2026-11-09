# Devices: simulators and emulators

Status: phase 1 shipped (Apple simulators and Android emulators). Phase 2 (Windows and Linux guests) is a design only.

## What phase 1 does

The **Devices** activity (sidebar, ⌘8, palette "Go to Devices") lists every Apple simulator and Android emulator or
attached device in one list, boots and shuts them down, and shows the screen of the selected one. The same operations are
the agent's and the MCP server's `device_*` tools; the view and the tools share one `DeviceService`
(`Core/Devices/DeviceService.swift`), so they cannot disagree about a device.

| Operation | Apple simulator (`xcrun simctl`) | Android (`adb`, `emulator`) |
|---|---|---|
| List | `simctl list devices -j` (unavailable runtimes are kept, greyed, with the reason) | `adb devices -l` + `emulator -list-avds`; a running AVD is shown once, under its serial |
| Boot / shut down | `simctl boot` + `bootstatus`; `simctl shutdown` | `emulator -avd <name> -no-snapshot-save`, waits for `sys.boot_completed`; `adb emu kill` |
| Screenshot | `simctl io <id> screenshot --type=png -` | `adb exec-out screencap -p` |
| Install / launch | `simctl install` (.app), `simctl launch <bundle id>` | `adb install -r` (.apk), `monkey` launcher or `am start -n pkg/activity` |
| Open URL | `simctl openurl` | `am start -a VIEW -d '<url>'` |
| Record video | `simctl io recordVideo` (interrupted with SIGINT after N s) | `screenrecord` then `adb pull` |
| Logs | `simctl spawn <id> log show --last 2m` | `logcat -d -t N` |
| Tap / swipe / type / key | **not available**, `simctl` has no input commands | `adb shell input tap/swipe/text/keyevent` |

The view refreshes the screenshot every 1.5 s while it is on screen and a booted device is selected (one capture at a
time, so a slow device is polled less often instead of queueing commands). On Android, clicking the image taps and
dragging swipes; coordinates are mapped to the screenshot's own pixel grid.

**Apple input is the honest gap.** There is no supported command-line way to inject touches or keys into the Simulator
(`simctl` has none; Facebook's `idb` and Xcode's private SimulatorKit do it, and neither is bundled). `device_input` on
an Apple simulator returns an error that says so instead of pretending. Moving around is still possible through
`device_open_url` and `device_launch`.

### Tools and permission levels

| Tool | Level | Why |
|---|---|---|
| `device_list`, `device_status`, `device_screenshot`, `device_logs` | read | observe only; screenshots go to `Application Support/Kiln/Devices/Captures`, never to a caller-chosen path |
| `device_boot`, `device_shutdown`, `device_install`, `device_launch` | execute | start or stop processes and change what is installed or running |
| `device_open_url`, `device_input`, `device_record_video` | write | change what the device shows, or write a recording |

Only the Workstation Agent profile enables `device_*`; read-only modes strip everything above read from the offered list
(gate A), and write/execute calls open the approval sheet like `re_*` and `lab_*`. Over MCP, reads are free and the rest
wait for approval in Kiln. Arguments that reach a shell (an Android package, activity, URL, typed text, keycode) are
validated or single-quoted before they go to `adb shell`, which joins its arguments into one command line.

### Missing tools

Tools are detected at runtime: `xcrun --find simctl`, and for Android `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`,
`~/Library/Android/sdk`, Homebrew's command-line-tools folders and `PATH`. A missing platform shows a "Setup needed"
card with what to install, and `device_status` says the same to the agent. **Kiln never downloads Xcode, SDKs,
simulator runtimes or system images.** Listing a platform does not require the other.

Two side effects worth knowing: `adb devices` starts the adb server (a background process) if it is not running, and a
booted emulator is a child process of Kiln, so it ends when Kiln quits.

## Sandbox and entitlements

`Config/Entitlements.plist` today declares **only** `com.apple.security.device.audio-input`. The app is *not* App
Sandboxed in release builds (the file says so: the agent runs real git, package managers and shells in any folder);
hardened runtime and notarization apply. So a Developer-ID release and a developer build behave the same here, and
phase 1 needs no new entitlement. This is what was verified; both were run unsandboxed.

If the app were sandboxed, this is what we expect (reasoning, **not tested**) the shell-outs would need, and why the
project should stay unsandboxed:

- Executing `/usr/bin/xcrun`, `simctl` and Xcode's tools: a sandboxed child inherits the sandbox. `simctl` talks to
  CoreSimulatorService over Mach, which the sandbox is expected to refuse; there is no public entitlement that allows
  it. Apple simulators would not work.
- Reading `~/Library/Android/sdk` and writing AVD state under `~/.android`: would need user-selected bookmarks or
  `com.apple.security.temporary-exception.files.home-relative-path.read-write`, and temporary exceptions are not
  accepted for Mac App Store apps.
- adb's server on `localhost:5037` and the emulator's console/adb ports: `network.client` and `network.server`.
- The emulator itself (Hypervisor.framework, GPU): a sandboxed child of the app would need it to run under the app's
  own entitlements; not something to rely on.

Conclusion: the Devices activity is a direct-distribution feature. If a Mac App Store build ever exists, Devices would
have to be compiled out or reduced to a helper that the user installs separately.

## Tests

`Tests/DevicesTests/DeviceTests.swift` against fixtures in `Tests/Fixtures/Devices/` (a trimmed real
`simctl list devices -j`, `adb devices -l` including unauthorized/offline entries and the daemon-start banner,
`emulator -list-avds` with and without INFO noise, `wm size`, `emu avd name`): parsers; tool discovery order; merging
both platforms; one platform failing; missing tools; boot, screenshot and input commands per platform with a scripted
`CommandRunning`; argument validation before anything touches a device; tool names, permission levels, gate A and the
Workstation profile. The live checks (a real booted simulator, the real app) are recorded in the PR/commit notes, not in
the test suite, because they depend on this Mac's Xcode and leave processes behind.

## Phase 2 (design only): Windows and Linux guests

Goal: UTM/QEMU and Apple Virtualization guests appear in the same list, with the same tools, so `device_list`,
`device_boot`, `device_screenshot` and `device_input` work on a Windows or Linux VM exactly as on a simulator.

### One protocol

Phase 1 keeps backends as `switch device.platform` inside `DeviceService`. Phase 2 extracts that into:

```swift
protocol DeviceBackend: Sendable {
    var id: String { get }                       // "simctl", "adb", "utm", "qemu", "vz"
    func detect() async -> BackendStatus         // found / missing + how to set up
    func list() async throws -> [DeviceInfo]
    func boot(_ d: DeviceInfo) async throws
    func shutdown(_ d: DeviceInfo, force: Bool) async throws
    func screenshot(_ d: DeviceInfo) async throws -> Data          // PNG
    var capabilities: Set<DeviceCapability> { get }                // .input, .install, .launch, .logs, .video, .urls
    func send(_ input: DeviceInput, to d: DeviceInfo) async throws // only if .input
}
```

`DeviceInfo.Platform` grows `.windows`, `.linux`, `.macos` and `Origin` gains `.vm`; ids carry the backend
(`utm:<uuid>`, `qemu:<name>`, `vz:<uuid>`). The agent tools stay as they are; a tool on a device whose backend lacks the
capability answers "not supported by <backend>: …", as Apple input does now. `device_install` and `device_launch` become
"push a file" and "run a command" for guests, which is a different (and riskier) trust level, so those would be new
execute-level tools (`device_guest_exec`) rather than overloads.

### Backends

1. **UTM (recommended first step).** UTM drives QEMU (with Hypervisor.framework for same-architecture guests) and
   Apple Virtualization, and ships `utmctl` (`/Applications/UTM.app/Contents/MacOS/utmctl`): `list`, `status`, `start`,
   `stop`, `suspend`, `ip-address`, `attach`. It has no screenshot or input command, so on its own UTM gives list /
   boot / stop only. Detection: UTM.app present. Fits phase 1's pattern (shell out, parse). No new entitlement for an
   unsandboxed Kiln.
2. **QEMU direct, driven over QMP.** For VMs Kiln launches itself (`qemu-system-aarch64 -accel hvf … -qmp unix:…`):
   QMP gives `screendump` (PNG/PPM), `send-key`, `input-send-event` (absolute pointer, buttons, keys),
   `system_powerdown` / `quit`. This is the only route that gives screenshots *and* input for Windows/Linux guests with
   no guest agent. Kiln would own the VM definitions (a small JSON per VM under `Application Support/Kiln/Devices/VMs`)
   and need the user's own QEMU (`brew install qemu`); nothing is bundled or downloaded. Windows 11 on Apple silicon runs
   under QEMU/HVF with an ARM64 Windows ISO and a TPM emulator (`swtpm`) the user supplies; the licence and ISO are the
   user's, and Kiln must ask before fetching anything.
3. **Apple Virtualization framework (`VZVirtualMachine`) for Linux and macOS guests.** In-process, needs the
   `com.apple.security.virtualization` entitlement (works with or without the sandbox) and a signed build. Linux guests
   boot an ARM64 ISO through `VZEFIBootLoader`; macOS guests install from an IPSW (`VZMacOSRestoreImage`) and are limited
   by Apple's licence to two concurrent macOS VMs. Display is a `VZVirtualMachineView` (live, no polling) and input
   goes through the view, which suits the UI but not headless agent use; for the agent a screenshot would come from
   snapshotting that view (needs the view on screen) or from a second framebuffer path, which is the open problem for
   this backend. It does not run Windows. Disk images and restore images are large downloads: always ask first.
4. **Android (existing) and cloud/remote devices** stay as they are; a remote ADB (`adb connect host:port`) is just a
   physical-origin Android device and already works through the phase 1 backend.

### Order of work

1. Extract `DeviceBackend` and move simctl/adb behind it (pure refactor, tests unchanged).
2. UTM list/start/stop (no input), shown with a "no screenshot from UTM" capability gap.
3. QEMU/QMP backend with screenshot and input, own VM definitions, `Origin.vm`.
4. Virtualization.framework Linux backend with an on-screen live view.
5. Guest exec/file push as separate execute-level tools, off by default, after a security review.

### What would break the design

- The sandbox (above): the VM backends all need to spawn processes or hold the virtualization entitlement.
- Image/ISO provenance: none of this downloads media; setup cards point to the vendor and the user picks the file.
- Resource limits: a Windows guest wants 4+ cores and 8 GB; `device_boot` should refuse when `lab_hardware`-style
  memory checks say the Mac cannot host it, rather than start and swap.
