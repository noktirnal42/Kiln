import SwiftUI

/// Sheet for read-only access to an external debug probe. The consent statement is part of
/// the form: nothing connects until it is ticked, and the bench itself refuses without it.
struct REDeviceBenchView: View {
    let bench: REDeviceBench

    @Environment(\.dismiss) private var dismiss
    @State private var host = "127.0.0.1"
    @State private var port = "3333"
    @State private var consent = false
    @State private var connected = false
    @State private var address = "0x0"
    @State private var length = "16"
    @State private var output = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Device Bench").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Connects to a GDB remote-protocol probe you started yourself (OpenOCD, QEMU gdbstub, pyOCD). "
                 + "Read-only: halt reason, registers and memory. Nothing is written to the target. "
                 + "Each session is logged, without the bytes read.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if connected {
                connectedControls
            } else {
                connectForm
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                Text(output.isEmpty ? "No output yet." : output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .task { connected = await bench.isConnected }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Host", text: $host).textFieldStyle(.roundedBorder)
                TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            Toggle("I own this target, or am authorized to inspect it, and consent to read-only access.",
                   isOn: $consent)
                .toggleStyle(.checkbox)
            Button("Connect") { Task { await connect() } }
                .disabled(busy || !consent)
            Text("Only loopback hosts (127.0.0.1, localhost, ::1) are enabled.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var connectedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Halt reason") { Task { await perform { try await bench.haltReason() } } }
                Button("Registers") {
                    Task { await perform { REHexFormat.hexDump(try await bench.readRegisters(), base: nil) } }
                }
                Spacer()
                Button("Disconnect", role: .destructive) { Task { await disconnect() } }
            }
            .disabled(busy)
            HStack {
                TextField("Address (hex)", text: $address).textFieldStyle(.roundedBorder)
                TextField("Bytes", text: $length).textFieldStyle(.roundedBorder).frame(width: 90)
                Button("Read memory") { Task { await readMemory() } }.disabled(busy)
            }
        }
    }

    private func connect() async {
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            error = "Port must be a number."
            return
        }
        await perform {
            try await bench.connect(host: host, port: portNumber, consent: consent)
            return "Connected to \(host):\(portNumber)."
        }
    }

    private func disconnect() async {
        await perform {
            try await bench.disconnect()
            return "Disconnected."
        }
    }

    private func readMemory() async {
        guard let base = REHexFormat.parseAddress(address) else {
            error = "Address must be hexadecimal, for example 0x1000."
            return
        }
        guard let count = Int(length.trimmingCharacters(in: .whitespaces)), (1...65536).contains(count) else {
            error = "Bytes must be a number from 1 to 65536."
            return
        }
        await perform { REHexFormat.hexDump(try await bench.readMemory(address: base, length: count), base: base) }
    }

    /// Runs one bench action, shows its result or error, then re-reads the connection state from the
    /// bench so a failed detach (which still ends the session) is reflected correctly.
    private func perform(_ work: () async throws -> String) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            output = try await work()
        } catch {
            self.error = error.localizedDescription
        }
        connected = await bench.isConnected
    }
}

/// Pure formatting helpers for the bench. A plain nonisolated type (not on the View) so they are
/// callable from any context and unit-testable off the main actor.
enum REHexFormat {
    /// Accepts `0x1000` or `1000`; returns nil for anything that is not hexadecimal.
    static func parseAddress(_ text: String) -> UInt64? {
        var trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("0x") { trimmed.removeFirst(2) }
        return UInt64(trimmed, radix: 16)
    }

    /// 16 bytes per line: offset, hex, printable ASCII. With `base` nil the offsets start at zero (register blobs have no address).
    static func hexDump(_ bytes: [UInt8], base: UInt64?) -> String {
        guard !bytes.isEmpty else { return "(empty)" }
        let start = base ?? 0
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = Array(bytes[offset..<min(offset + 16, bytes.count)])
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = String(row.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "0x%08llx  ", start + UInt64(offset)) + padded + "  " + ascii
        }.joined(separator: "\n")
    }
}
