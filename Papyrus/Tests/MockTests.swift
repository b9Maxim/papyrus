import XCTest
@testable import Papyrus

final class MockTests: XCTestCase {
    /// A mock called many times, with a suspension inside, used to hang once the task
    /// resumed on another thread while the mock's mutex was still held.
    func testMockCalledRepeatedlyAcrossSuspensionsDoesNotHang() async throws {
        let mock = _CounterMock()
        mock.mockCount {
            try await Task.sleep(nanoseconds: 1_000)
            return 1
        }

        var total = 0
        for _ in 0..<200 {
            total += try await mock.count()
        }

        XCTAssertEqual(total, 200)
    }

    func testMockCalledConcurrentlyDoesNotHang() async throws {
        let mock = _CounterMock()
        mock.mockCount {
            await Task.yield()
            return 1
        }

        let total = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask { try await mock.count() }
            }
            return try await group.reduce(0, +)
        }

        XCTAssertEqual(total, 100)
    }

    func testUnmockedEndpointThrows() async {
        let mock = _CounterMock()
        do {
            _ = try await mock.count()
            XCTFail("Expected the not-mocked error")
        } catch {
            XCTAssertEqual((error as? PapyrusError)?.message, "Not mocked")
        }
    }
}

@API()
@Mock()
protocol _Counter {
    @GET("count")
    func count() async throws -> Int
}
