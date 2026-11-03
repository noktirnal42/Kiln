import FakeMacKit
setvbuf(stdout, nil, _IOLBF, 0)
import Foundation

let server = FakeMacServer(advertise: true)
try await server.start()
print("Fake Kiln listening on port \(server.port), advertising as \"\(server.serviceName)\".")
print("Pair with this link (paste into the companion, or `xcrun simctl openurl booted '<link>'`):")
print(server.pairing.url.absoluteString)
while true { try await Task.sleep(for: .seconds(3600)) }
