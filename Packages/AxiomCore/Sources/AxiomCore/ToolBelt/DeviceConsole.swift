import Foundation
import Darwin

// Device bench (docs/KALI_METASPLOIT_PARITY.md T7): the lab bench for connected-device RE —
// a serial-over-USB console with capture, and a GDB remote-serial-protocol client for external
// debug probes (OpenOCD, QEMU, pyOCD). Axiom speaks the documented protocols natively and does
// not bundle the GPL daemons; the analyst configures those separately. Device-facing I/O is
// consent-gated: every session opens with an explicit consent flag and is audit-logged via
// DeviceSessionRecord, carrying the stability/side-effect discipline adopted from the
// Metasploit determination in the parity doc.

/// One audit entry for a device-bench interaction. Captured console bytes never include key
/// material handling — this records what was done, not what was recovered.
public struct DeviceSessionRecord: Codable, Sendable {
    public let kind: String            // "serial" | "gdb"
    public let target: String          // device path or host:port
    public let started: Date
    public let ended: Date?
    public let bytesCaptured: Int
    public let consent: String         // "analyst-requested" — recorded so logs are self-describing
    public let sideEffects: String     // e.g. "read-only capture" / "halt+memory-read"
    public let notes: [String]

    public init(kind: String, target: String, started: Date = Date(), ended: Date? = nil,
                bytesCaptured: Int = 0, consent: String = "analyst-requested",
                sideEffects: String, notes: [String] = []) {
        self.kind = kind; self.target = target; self.started = started; self.ended = ended
        self.bytesCaptured = bytesCaptured; self.consent = consent; self.sideEffects = sideEffects; self.notes = notes
    }
}

public enum SerialPort {
    /// Candidate serial devices: USB-serial adapters and the pseudo-terminal test seam.
    public static func availableDevices() -> [String] {
        let directories = ["/dev"]
        var found: [String] = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names where name.hasPrefix("tty.usb") || name.hasPrefix("cu.usb") || name.hasPrefix("ttys") {
                found.append(directory + "/" + name)
            }
        }
        return found.sorted()
    }

    static func baudConstant(_ baud: Int) -> speed_t? {
        // termios baud symbols are not guaranteed contiguous; map the common console rates.
        let table: [Int: speed_t] = [9600: speed_t(B9600), 19200: speed_t(B19200), 38400: speed_t(B38400),
                                     57600: speed_t(B57600), 115200: speed_t(B115200), 230400: speed_t(B230400)]
        return table[baud]
    }

    /// Opens and configures a serial device in raw 8N1 mode. Returns the file descriptor; the
    /// caller owns closing it. Throws with the errno detail so console failures are legible.
    public static func open(path: String, baud: Int) throws -> Int32 {
        guard let speed = baudConstant(baud) else {
            throw AxiomError.message("Unsupported baud \(baud). Supported: 9600, 19200, 38400, 57600, 115200, 230400.")
        }
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw AxiomError.message("Cannot open \(path): errno \(errno).") }
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            close(descriptor); throw AxiomError.message("tcgetattr failed on \(path): errno \(errno).")
        }
        cfmakeraw(&settings)
        cfsetispeed(&settings, speed)
        cfsetospeed(&settings, speed)
        settings.c_cflag |= UInt(CS8)
        settings.c_cc.16 = 1   // VMIN: return per byte
        settings.c_cc.17 = 0   // VTIME: no inter-byte wait
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            close(descriptor); throw AxiomError.message("tcsetattr failed on \(path): errno \(errno).")
        }
        return descriptor
    }
}

/// A live serial console session: reads the device, timestamps and captures everything, and can
/// transmit lines. Everything is bounded per the app-wide output rules; capture is the artifact.
public final class DeviceConsole {
    public private(set) var lines: [String] = []
    public private(set) var byteCount = 0
    public private(set) var record: DeviceSessionRecord
    private let descriptor: Int32
    private var buffer: [UInt8] = []

    /// `consent` must be true — the console transmits to and reads from a physical device.
    public init(devicePath: String, baud: Int = 115200, consent: Bool) throws {
        guard consent else { throw AxiomError.message("Device I/O requires explicit consent; refused without it.") }
        descriptor = try SerialPort.open(path: devicePath, baud: baud)
        record = DeviceSessionRecord(kind: "serial", target: devicePath, sideEffects: "read-only capture; transmitted lines are logged in notes")
    }

    deinit { close(descriptor) }

    /// Drains available bytes for up to `seconds`, appending timestamped lines to the capture.
    /// Returns the new lines. Bounded: stops early if the line cap is reached.
    @discardableResult
    public func capture(seconds: Double, maxLines: Int = 4096) throws -> [String] {
        let deadline = Date().addingTimeInterval(max(0, min(seconds, 3600)))
        var newLines: [String] = []
        while Date() < deadline, lines.count < maxLines {
            var byte = UInt8(0)
            let n = read(descriptor, &byte, 1)
            if n > 0 {
                byteCount += 1
                if byte == 0x0a {
                    appendBufferedLine()
                    if let last = lines.last { newLines.append(last) }
                } else if byte != 0x0d {
                    buffer.append(byte)
                    if buffer.count > 4096 { appendBufferedLine() }
                }
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        if !buffer.isEmpty { appendBufferedLine(); if let last = lines.last { newLines.append(last) } }
        record = DeviceSessionRecord(kind: record.kind, target: record.target, started: record.started,
                                     ended: Date(), bytesCaptured: byteCount, consent: record.consent,
                                     sideEffects: record.sideEffects, notes: record.notes)
        return newLines
    }

    /// Transmits one line (newline appended). The line is recorded in the audit notes —
    /// transmitted input is a side effect and must be visible in the session record.
    public func send(line: String) throws {
        guard line.utf8.count <= 4096 else { throw AxiomError.message("Line exceeds 4 KiB.") }
        let payload = Data((line + "\n").utf8)
        guard payload.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == payload.count else {
            throw AxiomError.message("Serial write failed: errno \(errno).")
        }
        record = DeviceSessionRecord(kind: record.kind, target: record.target, started: record.started,
                                     ended: record.ended, bytesCaptured: byteCount, consent: record.consent,
                                     sideEffects: record.sideEffects, notes: record.notes + ["sent: \(line.prefix(200))"])
    }

    /// Boot-log search across the capture: case-insensitive substring with line numbers.
    public func search(_ query: String) -> [(line: Int, text: String)] {
        lines.enumerated().compactMap { index, text in
            text.localizedCaseInsensitiveContains(query) ? (index + 1, text) : nil
        }
    }

    private func appendBufferedLine() {
        lines.append(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll(keepingCapacity: true)
    }
}
