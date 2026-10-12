import XCTest
@testable import Papyrus


final class CurlTests: XCTestCase {
    func testConvertPath() throws {
        let req = RequestBuilder(baseURL: "foo/", method: "bar", path: "baz")

        let request = try TestRequest(from: req)

        // Assert Multi Line
        XCTAssertEqual(request.curl(sortedHeaders: true), """
        curl 'foo/baz' \\
        -X bar \\
        -H 'Content-Length: 0' \\
        -H 'Content-Type: application/json'
        """)
    }

    func testConvertHeaders() async throws {
        var req = RequestBuilder(baseURL: "foo/", method: "GET", path: "/baz")
        req.addHeader("Hello", value: "There")
        req.addHeader("High", value: "Ground")

        let request = try TestRequest(from: req)

        let normalizedCurl = request.curl(sortedHeaders: true)

        XCTAssertEqual(normalizedCurl, """
        curl 'foo/baz' \\
        -X GET \\
        -H 'Content-Length: 0' \\
        -H 'Content-Type: application/json' \\
        -H 'Hello: There' \\
        -H 'High: Ground'
        """)
    }

    func testConvertMultipart() throws {
        var req = RequestBuilder(baseURL: "foo/", method: "bar", path: "/baz")
        let encoder = MultipartEncoder(boundary: UUID().uuidString)
        req.requestBodyEncoder = encoder
        req.addField("a", value: Part(data: Data("one".utf8), fileName: "one.txt", mimeType: "text/plain"))
        req.addField("b", value: Part(data: Data("two".utf8)))

        let request = try TestRequest(from: req)

        XCTAssertEqual(request.curl(sortedHeaders: true), """
        curl 'foo/baz' \\
        -X bar \\
        -H 'Content-Length: 266' \\
        -H 'Content-Type: multipart/form-data; boundary=\(encoder.boundary)' \\
        -d '--\(encoder.boundary)\r
        Content-Disposition: form-data; name="a"; filename="one.txt"\r
        Content-Type: text/plain\r
        \r
        one\r
        --\(encoder.boundary)\r
        Content-Disposition: form-data; name="b"\r
        \r
        two\r
        --\(encoder.boundary)--\r
        '
        """)
    }

    func testConvertJSON() async throws {
        var req = RequestBuilder(baseURL: "foo/", method: "bar", path: "/baz")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        req.requestBodyEncoder = encoder
        req.addField("a", value: "one")
        req.addField("b", value: "two")

        let request = try TestRequest(from: req)

        let s = """
        curl 'foo/baz' \\
        -X bar \\
        -H 'Content-Length: 32' \\
        -H 'Content-Type: application/json' \\
        -d '{
          "a" : "one",
          "b" : "two"
        }'
        """

        XCTAssertEqual(request.curl(sortedHeaders: true), s)
    }

    func testConvertURLForm() async throws {
        var req = RequestBuilder(baseURL: "foo/", method: "bar", path: "/baz")
        req.requestBodyEncoder = URLEncodedFormEncoder()
        req.addField("a", value: "one")
        req.addField("b", value: "two")

        let request = try TestRequest(from: req)

        let normalizedCurl = request.curl(sortedHeaders: true)
            .replacingOccurrences(of: "b=two&a=one", with: "a=one&b=two")

        XCTAssertEqual(normalizedCurl, """
        curl 'foo/baz' \\
        -X bar \\
        -H 'Content-Length: 11' \\
        -H 'Content-Type: application/x-www-form-urlencoded' \\
        -d 'a=one&b=two'
        """)
    }

    func testInterceptorAlways() async throws {
        var req = RequestBuilder(baseURL: "foo/", method: "GET", path: "/baz")
        req.addQuery("Hello", value: "There")
        req.addHeader("High", value: "Ground")
        let request = try TestRequest(from: req)

        let message: ResourceMutex<String?> = .init(resource: nil)

        let logger = CurlLogger(when: .always, using: { value in
            message.withLock { resource in
                resource = value
            }
        })

        _ = try await logger.intercept(req: request) { req in
            return TestResponse(request: req)
        }
        
        message.withLock { resource in
            XCTAssertNotNil(resource, "Logger did not output")

            guard let resource else { return }

            XCTAssertEqual(resource, """
            curl 'foo/baz?Hello=There' \\
            -X GET \\
            -H 'Content-Length: 0' \\
            -H 'Content-Type: application/json' \\
            -H 'High: Ground'
            """)
        }
    }

    func testInterceptorOnError() async throws {
        var req = RequestBuilder(baseURL: "foo/", method: "GET", path: "/baz")
        req.addQuery("Hello", value: "There")
        req.addHeader("High", value: "Ground")
        let request = try TestRequest(from: req)

        let message: ResourceMutex<String?> = .init(resource: nil)

        let logger = CurlLogger(when: .onError, using: { value in
            message.withLock { resource in
                resource = value
            }
        })

        _ = try? await logger.intercept(req: request) { req in
            throw PapyrusError("")
        }

        message.withLock { resource in
            XCTAssertNotNil(resource, "Logger did not output")
            guard let resource else { return }
            XCTAssertEqual(resource, """
            curl 'foo/baz?Hello=There' \\
            -X GET \\
            -H 'Content-Length: 0' \\
            -H 'Content-Type: application/json' \\
            -H 'High: Ground'
            """)
        }
    }

    func testInterceptorOnErrorNoError() async throws {
        var req = RequestBuilder(baseURL: "foo/", method: "GET", path: "/baz")
        req.addQuery("Hello", value: "There")
        req.addHeader("High", value: "Ground")

        let request = try TestRequest(from: req)

        let message: ResourceMutex<String?> = .init(resource: nil)

        let logger = CurlLogger(when: .onError, using: { value in
            message.withLock { resource in
                resource = value
            }
        })

        _ = try await logger.intercept(req: request) { req in
            return TestResponse(request: req)
        }

        message.withLock { resource in
            XCTAssertNil(resource, "Logger did output")
        }
    }

    func testInterceptorOnErrorLogsResponseCarryingError() async throws {
        let request = try _loggedRequest()
        let messages: ResourceMutex<[String]> = .init(resource: [])
        let logger = CurlLogger(when: .onError, using: { value in messages.withLock { $0.append(value) } })

        _ = try await logger.intercept(req: request) { req in
            TestResponse(request: req, error: URLError(.notConnectedToInternet))
        }

        messages.withLock { XCTAssertEqual($0, [_loggedCurl]) }
    }

    func testInterceptorOnErrorLogsUnsuccessfulStatus() async throws {
        let request = try _loggedRequest()
        let messages: ResourceMutex<[String]> = .init(resource: [])
        let logger = CurlLogger(when: .onError, using: { value in messages.withLock { $0.append(value) } })

        _ = try await logger.intercept(req: request) { req in
            TestResponse(request: req, statusCode: 500)
        }

        messages.withLock { XCTAssertEqual($0, [_loggedCurl]) }
    }

    func testInterceptorOnErrorSkipsSuccessfulStatus() async throws {
        let request = try _loggedRequest()
        let messages: ResourceMutex<[String]> = .init(resource: [])
        let logger = CurlLogger(when: .onError, using: { value in messages.withLock { $0.append(value) } })

        _ = try await logger.intercept(req: request) { req in
            TestResponse(request: req, statusCode: 200)
        }

        messages.withLock { XCTAssertEqual($0, []) }
    }

    func testInterceptorOnErrorLogsOnceAndRethrowsThrownError() async throws {
        let request = try _loggedRequest()
        let messages: ResourceMutex<[String]> = .init(resource: [])
        let logger = CurlLogger(when: .onError, using: { value in messages.withLock { $0.append(value) } })

        do {
            _ = try await logger.intercept(req: request) { _ in throw URLError(.timedOut) }
            XCTFail("The logger must rethrow the error of the interceptor below it.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }

        messages.withLock { XCTAssertEqual($0, [_loggedCurl]) }
    }
}

private func _loggedRequest() throws -> TestRequest {
    var req = RequestBuilder(baseURL: "foo/", method: "GET", path: "/baz")
    req.addQuery("Hello", value: "There")
    req.addHeader("High", value: "Ground")
    return try TestRequest(from: req)
}

private let _loggedCurl = """
    curl 'foo/baz?Hello=There' \\
    -X GET \\
    -H 'Content-Length: 0' \\
    -H 'Content-Type: application/json' \\
    -H 'High: Ground'
    """

private struct TestResponse: PapyrusResponse {
    var request: (any PapyrusRequest)? = nil
    var body: Data? = nil
    var headers: [String : String]? = nil
    var statusCode: Int? = nil
    var error: (any Error)? = nil
}

private struct TestRequest: PapyrusRequest {
    var method: String
    var url: URL?
    var headers: [String : String]
    var body: Data?

    init(method: String, url: URL?, headers: [String : String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    init(from builder: RequestBuilder) throws {
        let url = try builder.fullURL()
        let (body, headers) = try builder.bodyAndHeaders()

        self.init(
            method: builder.method,
            url: url,
            headers: headers,
            body: body
        )
    }
}
