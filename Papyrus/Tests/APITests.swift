import XCTest
@testable import Papyrus

final class APITests: XCTestCase {
    func testApiEndpointReturnsNilForOptionalReturnType_forNilBody() async throws {
        // Arrange
        let sut = _PeopleAPI(provider: .init(baseURL: "", http: _HTTPServiceMock(responseType: .nil)))
        
        // Act
        let person = try await sut.getOptional()
        
        // Assert
        XCTAssertNil(person)
    }
    
    func testApiEndpointThrowsForNonOptionalReturnType_forNilBody() async throws {
        // Arrange
        let sut = _PeopleAPI(provider: .init(baseURL: "", http: _HTTPServiceMock(responseType: .nil)))
        
        // Act
        let expectation = expectation(description: "The endpoint with the non-optional return type should throw an error for an invalid body.")
        do {
            let _ = try await sut.get()
        } catch {
            expectation.fulfill()
        }

        // Assert
        await fulfillment(of: [expectation], timeout: 1)
    }
    
    func testApiEndpointReturnsNilForOptionalReturnType_forEmptyBody() async throws {
        // Arrange
        let sut = _PeopleAPI(provider: .init(baseURL: "", http: _HTTPServiceMock(responseType: .empty)))
        
        // Act
        let person = try await sut.getOptional()
        
        // Assert
        XCTAssertNil(person)
    }
    
    func testApiEndpointThrowsForNonOptionalReturnType_forEmptyBody() async throws {
        // Arrange
        let sut = _PeopleAPI(provider: .init(baseURL: "", http: _HTTPServiceMock(responseType: .empty)))
        
        // Act
        let expectation = expectation(description: "The endpoint with the non-optional return type should throw an error for an invalid body.")
        do {
            let _ = try await sut.get()
        } catch {
            expectation.fulfill()
        }

        // Assert
        await fulfillment(of: [expectation], timeout: 1)
    }
    
    func testApiEndpointReturnsValidObjectForOptionalReturnType() async throws {
        // Arrange
        let sut = _PeopleAPI(provider: .init(baseURL: "", http: _HTTPServiceMock(responseType: .person)))
        
        // Act
        let person = try await sut.getOptional()
        
        // Assert
        XCTAssertNotNil(person)
        XCTAssertEqual(person?.name, "Petru")
    }
    
    func testApiEndpointReturnsValidObjectForNonOptionalReturnType() async throws {
        // Arrange
        let sut = _PeopleAPI(provider: .init(baseURL: "", http: _HTTPServiceMock(responseType: .person)))
        
        // Act
        let person = try await sut.get()
        
        // Assert
        XCTAssertNotNil(person)
        XCTAssertEqual(person.name, "Petru")
    }

    func testMultipartEndpointOmitsNilOptionalPart() async throws {
        // Arrange
        let sut = _UploadsAPI(provider: .init(baseURL: "", http: _EchoHTTPService()))

        // Act
        let response = try await sut.upload(file: Part(data: Data("one".utf8)), thumbnail: nil)

        // Assert
        let body = String(decoding: response.request?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="file""#))
        XCTAssertFalse(body.contains(#"name="thumbnail""#))
    }
}

@API()
@Multipart
fileprivate protocol _Uploads {

    @POST("upload")
    func upload(file: Part, thumbnail: Part?) async throws -> PapyrusResponse
}

/// Echoes the built request back inside the response, so a test can read what was sent.
fileprivate struct _EchoHTTPService: HTTPService {

    func build(method: String, url: URL, headers: [String: String], body: Data?) -> any PapyrusRequest {
        _Request(url: url, method: method, headers: headers, body: body)
    }

    func request(_ req: any PapyrusRequest) async -> any PapyrusResponse {
        _Response(request: req, statusCode: 200)
    }
}

@API()
fileprivate protocol _People {
    
    @GET("")
    func getOptional() async throws -> _Person?
    
    @GET("")
    func get() async throws -> _Person
}

fileprivate struct _Person: Decodable {
    let name: String
}

fileprivate struct _HTTPServiceMock: HTTPService {
    
    enum ResponseType {
        case `nil`
        case empty
        case person
        
        var value: String? {
            switch self {
            case .nil:
                nil
            case .empty:
                ""
            case .person:
                "{\"name\": \"Petru\"}"
            }
        }
    }
    
    private let _responseType: ResponseType
    
    init(responseType: ResponseType) {
        _responseType = responseType
    }
    
    func build(method: String, url: URL, headers: [String : String], body: Data?) -> any PapyrusRequest {
        _Request(method: "", headers: [:])
    }
    
    func request(_ req: any PapyrusRequest) async -> any PapyrusResponse {
        _Response(body: _responseType.value?.data(using: .utf8), statusCode: 200)
    }
    
    func request(_ req: any PapyrusRequest, completionHandler: @escaping (any PapyrusResponse) -> Void) {
        completionHandler(_Response(body: "".data(using: .utf8)))
    }
}

fileprivate struct _Request: PapyrusRequest {
    var url: URL?
    var method: String
    var headers: [String : String]
    var body: Data?
}

fileprivate struct _Response: PapyrusResponse {
    var request: (any PapyrusRequest)?
    var body: Data?
    var headers: [String : String]?
    var statusCode: Int?
    var error: (any Error)?
}
