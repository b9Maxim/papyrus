import XCTest
@testable import Papyrus

final class RetryInterceptorTests: XCTestCase {
    func testRetriesIdempotentRequestUntilSuccess() async throws {
        let server = _ScriptedServer([.status(503), .status(503), .status(200)])

        let response = try await _instantRetry().intercept(req: _request("GET"), next: server.next)

        XCTAssertEqual(response.statusCode, 200)
        let calls = await server.calls
        XCTAssertEqual(calls, 3)
    }

    func testDoesNotRetryPost() async throws {
        let server = _ScriptedServer([.status(503), .status(200)])

        let response = try await _instantRetry().intercept(req: _request("POST"), next: server.next)

        XCTAssertEqual(response.statusCode, 503)
        let calls = await server.calls
        XCTAssertEqual(calls, 1)
    }

    func testReturnsLastResponseWhenAttemptsRunOut() async throws {
        let server = _ScriptedServer([.status(502), .status(503), .status(504), .status(200)])
        let sleeps = _Sleeps()

        let response = try await _instantRetry(maxAttempts: 3, sleeps: sleeps)
            .intercept(req: _request("GET"), next: server.next)

        XCTAssertEqual(response.statusCode, 504)
        let calls = await server.calls
        XCTAssertEqual(calls, 3)
        let delays = await sleeps.delays
        XCTAssertEqual(delays.count, 2)
    }

    func testRetriesDroppedConnection() async throws {
        let server = _ScriptedServer([.failure(.networkConnectionLost), .status(200)])

        let response = try await _instantRetry().intercept(req: _request("GET"), next: server.next)

        XCTAssertEqual(response.statusCode, 200)
        let calls = await server.calls
        XCTAssertEqual(calls, 2)
    }

    func testDoesNotRetryClientError() async throws {
        let server = _ScriptedServer([.status(404), .status(200)])

        let response = try await _instantRetry().intercept(req: _request("GET"), next: server.next)

        XCTAssertEqual(response.statusCode, 404)
        let calls = await server.calls
        XCTAssertEqual(calls, 1)
    }

    func testBackoffDoublesUntilCappedAtMaxDelay() async throws {
        let server = _ScriptedServer([.status(503), .status(503), .status(503), .status(200)])
        let sleeps = _Sleeps()

        _ = try await _instantRetry(maxAttempts: 4, baseDelay: 2, maxDelay: 5, sleeps: sleeps)
            .intercept(req: _request("GET"), next: server.next)

        let delays = await sleeps.delays
        XCTAssertEqual(delays, [2, 4, 5])
    }

    func testRetryAfterReplacesBackoff() async throws {
        let server = _ScriptedServer([.status(503, headers: ["retry-after": "2"]), .status(200)])
        let sleeps = _Sleeps()

        let response = try await _instantRetry(baseDelay: 0.5, sleeps: sleeps)
            .intercept(req: _request("GET"), next: server.next)

        XCTAssertEqual(response.statusCode, 200)
        let delays = await sleeps.delays
        XCTAssertEqual(delays, [2])
    }

    func testRetryAfterBeyondMaxDelayStopsRetrying() async throws {
        let server = _ScriptedServer([.status(503, headers: ["Retry-After": "60"]), .status(200)])

        let response = try await _instantRetry(maxDelay: 5).intercept(req: _request("GET"), next: server.next)

        XCTAssertEqual(response.statusCode, 503)
        let calls = await server.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancellationStopsRetrying() async throws {
        let server = _ScriptedServer([.status(503), .status(200)])
        let sut = RetryInterceptor(baseDelay: 30, maxDelay: 30)
        let task = Task {
            try await sut.intercept(req: _request("GET"), next: server.next)
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled request must not wait out the backoff and retry.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let calls = await server.calls
        XCTAssertEqual(calls, 1)
    }
}

/// A retry interceptor that records its delays instead of sleeping, with jitter turned off.
private func _instantRetry(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 0.5,
    maxDelay: TimeInterval = 5,
    sleeps: _Sleeps = _Sleeps()
) -> RetryInterceptor {
    var sut = RetryInterceptor(maxAttempts: maxAttempts, baseDelay: baseDelay, maxDelay: maxDelay)
    sut.jitter = { $0 }
    sut.sleep = { await sleeps.record($0) }
    return sut
}

private func _request(_ method: String) -> any PapyrusRequest {
    var request = URLRequest(url: URL(string: "https://example.com/items")!)
    request.httpMethod = method
    return request
}

/// Answers each attempt with the next scripted response and counts the attempts.
private actor _ScriptedServer {
    private var responses: [_StubResponse]
    private(set) var calls = 0

    init(_ responses: [_StubResponse]) {
        self.responses = responses
    }

    nonisolated var next: Interceptor.Next {
        { _ in await self.respond() }
    }

    private func respond() -> any PapyrusResponse {
        calls += 1
        return responses.removeFirst()
    }
}

private actor _Sleeps {
    private(set) var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }
}

private struct _StubResponse: PapyrusResponse {
    var request: (any PapyrusRequest)?
    var body: Data?
    var headers: [String: String]?
    var statusCode: Int?
    var error: (any Error)?

    static func status(_ code: Int, headers: [String: String]? = nil) -> _StubResponse {
        _StubResponse(headers: headers, statusCode: code)
    }

    static func failure(_ code: URLError.Code) -> _StubResponse {
        _StubResponse(error: URLError(code))
    }
}
