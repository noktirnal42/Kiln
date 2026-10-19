import XCTest
@testable import AxiomCore

final class EngineWorkerTests: XCTestCase {
    /// Stand-in for the Ghidra worker: same framing, no Ghidra. `slow` never replies; `cancel` is recorded.
    static let stub = """
    import sys, json, os
    def emit(o): sys.stdout.write("AXIOM " + json.dumps(o) + "\\n"); sys.stdout.flush()
    print("engine banner noise"); sys.stdout.flush()
    emit({"event": "progress", "phase": "import", "fraction": 0.5})
    emit({"event": "futureEvent"})
    emit({"event": "ready"})
    cancelled = []
    for line in sys.stdin:
        r = json.loads(line); m = r["method"]
        if m == "cancel": cancelled.append(r["params"]["target"]); continue
        if m == "echo": emit({"id": r["id"], "result": r["params"]})
        elif m == "cancelled": emit({"id": r["id"], "result": cancelled})
        elif m == "fail": emit({"id": r["id"], "error": {"message": "no such function"}})
        elif m == "big": emit({"id": r["id"], "result": "x" * 200000})
        elif m == "die": os._exit(3)
        elif m == "slow": pass
        elif m == "shutdown": emit({"id": r["id"], "result": "bye"}); break
        else: emit({"id": r["id"], "error": {"message": "unknown method"}})
    """

    private func makeWorker() throws -> EngineWorker {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-stub-\(UUID().uuidString).py")
        try Self.stub.write(to: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return EngineWorker(executable: "/usr/bin/env", arguments: ["python3", path.path])
    }
    private func decode(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

    func testEventsLogsAndRequestResponse() async throws {
        let worker = try makeWorker(); try await worker.start()
        var seen: [WorkerEvent] = []
        for await event in worker.events { seen.append(event); if event == .ready { break } }
        XCTAssertEqual(seen, [.log("engine banner noise"), .progress(phase: "import", fraction: 0.5), .other(name: "futureEvent"), .ready])
        let echoed = try decode(try await worker.request("echo", params: ["address": "100000460", "n": 7])) as? [String: Any]
        XCTAssertEqual(echoed?["address"] as? String, "100000460"); XCTAssertEqual(echoed?["n"] as? Int, 7)
        let big = try decode(try await worker.request("big")) as? String
        XCTAssertEqual(big?.count, 200000)
        await worker.shutdown()
        let running = await worker.isRunning
        XCTAssertFalse(running)
    }

    func testRemoteErrorsAndConcurrentRequestsAreMatchedById() async throws {
        let worker = try makeWorker(); try await worker.start()
        do { _ = try await worker.request("fail"); XCTFail("expected error") } catch { XCTAssertEqual(error as? WorkerError, .remote("no such function")) }
        async let a = worker.request("echo", params: ["k": "a"]), b = worker.request("echo", params: ["k": "b"]), c = worker.request("echo", params: ["k": "c"])
        let results = try await [a, b, c].map { (try decode($0) as? [String: Any])?["k"] as? String }
        XCTAssertEqual(results, ["a", "b", "c"])
        await worker.shutdown()
    }

    func testTimeoutStopsSilentWorkerAndLaterRequestsFail() async throws {
        let worker = try makeWorker(); try await worker.start()
        do { _ = try await worker.request("slow", timeout: 0.5); XCTFail("expected timeout") } catch { XCTAssertEqual(error as? WorkerError, .timedOut("slow")) }
        try await Task.sleep(nanoseconds: 800_000_000)
        do { _ = try await worker.request("echo"); XCTFail("expected failure") } catch { XCTAssertEqual(error as? WorkerError, .notRunning) }
    }

    func testTaskCancellationSendsCancelToWorkerAndKeepsItUsable() async throws {
        let worker = try makeWorker(); try await worker.start()
        let task = Task { try await worker.request("slow", timeout: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertEqual(error as? WorkerError, .cancelled) }
        let targets = try decode(try await worker.request("cancelled")) as? [Int]
        XCTAssertEqual(targets, [1], "the worker was told which request to abandon")
        await worker.shutdown()
    }

    func testWorkerCrashFailsInFlightRequestsWithExitStatus() async throws {
        let worker = try makeWorker(); try await worker.start()
        do { _ = try await worker.request("die"); XCTFail("expected exit") } catch { XCTAssertEqual(error as? WorkerError, .exited(3)) }
        var last: WorkerEvent?
        for await event in worker.events { last = event }
        XCTAssertEqual(last, .exited(status: 3))
    }

    func testRequestBeforeStartFails() async {
        let worker = EngineWorker(executable: "/usr/bin/true")
        do { _ = try await worker.request("echo"); XCTFail("expected error") } catch { XCTAssertEqual(error as? WorkerError, .notRunning) }
    }
}
