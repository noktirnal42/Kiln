import FakeMacKit
import Foundation
import KilnRemoteKit

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let relay = env["FAKEMAC_RELAY"].flatMap(URL.init(string:))
// FAKEMAC_NO_BONJOUR=1 hides the Mac from the local network, to exercise the relay path.
let server = FakeMacServer(advertise: env["FAKEMAC_NO_BONJOUR"] == nil)
try await server.start()
print("Fake Kiln listening on port \(server.port), advertising as \"\(server.serviceName)\".")
if let relay {
    try await server.connectToRelay(relay)
    print("Connected to relay \(relay.absoluteString) as the Mac.")
}
var payload = server.pairing
payload.relay = relay
print("Pair with this link (paste into the companion, or `xcrun simctl openurl booted '<link>'`):")
print(payload.url.absoluteString)
while true { try await Task.sleep(for: .seconds(3600)) }
