// Fixture for Kiln's reverse-engineering tests (Swift). Build: swiftc -Onone -o Tests/Fixtures/re-sample-swift Tests/Fixtures/re-sample-swift.swift
// Known facts: struct Greeter with method greet; free function fibonacci; the string KILN-SWIFT-FIXTURE is printed by main.
struct Greeter {
    let name: String
    func greet() -> String { "KILN-SWIFT-FIXTURE hello \(name)" }
}
func fibonacci(_ n: Int) -> Int { n < 2 ? n : fibonacci(n - 1) + fibonacci(n - 2) }
print(Greeter(name: "world").greet())
print(fibonacci(10))
