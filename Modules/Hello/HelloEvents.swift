import Foundation

public struct HelloPingEvent: ModuleEvent, Encodable, Equatable {
    public let eventType = "hello.ping"
    public let sourceModule: String
    public let timestamp = Date()
    public let message: String

    public init(sourceModule: String, message: String) {
        self.sourceModule = sourceModule
        self.message = message
    }
}
