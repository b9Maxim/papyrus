import Foundation
#if os(Linux)
import FoundationNetworking
#endif

/// An `Interceptor` that sends a request again after a transient failure: a dropped or
/// timed-out connection, or a 408, 429, 502, 503 or 504 response.
///
/// Only idempotent methods are retried by default. A `POST` that timed out may already
/// have reached the server, and sending it again could repeat its side effect.
///
/// Delays grow exponentially from `baseDelay` up to `maxDelay`, with jitter. A numeric
/// `Retry-After` header replaces the computed delay; one longer than `maxDelay` ends the
/// retries. When the attempts run out, the last response is returned unchanged.
///
/// Place it last in a `Provider`'s interceptors, closest to the network, so requests
/// re-sent by the interceptors before it are retried too.
public struct RetryInterceptor: Interceptor {
    /// Total sends, the first one included.
    public let maxAttempts: Int
    public let retryableMethods: Set<String>
    public let retryableStatusCodes: Set<Int>
    public let retryableErrorCodes: Set<URLError.Code>
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    /// Spreads the computed delay so clients that failed together do not retry together.
    var jitter: @Sendable (TimeInterval) -> TimeInterval = { $0 / 2 + .random(in: 0...$0 / 2) }
    var sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }

    public init(
        maxAttempts: Int = 3,
        retryableMethods: Set<String> = ["GET", "HEAD", "OPTIONS", "PUT", "DELETE"],
        retryableStatusCodes: Set<Int> = [408, 429, 502, 503, 504],
        retryableErrorCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ],
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 5
    ) {
        self.maxAttempts = maxAttempts
        self.retryableMethods = retryableMethods
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableErrorCodes = retryableErrorCodes
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func intercept(req: any PapyrusRequest, next: Next) async throws -> any PapyrusResponse {
        var attempt = 1
        while true {
            let response = try await next(req)
            guard attempt < maxAttempts, isRetryable(req, response), let delay = delay(after: response, attempt: attempt) else {
                return response
            }

            try await sleep(delay)
            attempt += 1
        }
    }

    private func isRetryable(_ req: any PapyrusRequest, _ response: any PapyrusResponse) -> Bool {
        guard retryableMethods.contains(req.method.uppercased()) else {
            return false
        }

        if let error = response.error as? URLError {
            return retryableErrorCodes.contains(error.code)
        }

        return response.statusCode.map(retryableStatusCodes.contains) ?? false
    }

    /// `nil` when the server asks to wait longer than `maxDelay`.
    private func delay(after response: any PapyrusResponse, attempt: Int) -> TimeInterval? {
        if let retryAfter = retryAfter(response) {
            return retryAfter <= maxDelay ? retryAfter : nil
        }

        return jitter(min(maxDelay, baseDelay * pow(2, Double(attempt - 1))))
    }

    /// The delta-seconds form only; an HTTP-date falls back to the computed delay.
    private func retryAfter(_ response: any PapyrusResponse) -> TimeInterval? {
        response.headers?
            .first { $0.key.lowercased() == "retry-after" }
            .flatMap { TimeInterval($0.value.trimmingCharacters(in: .whitespaces)) }
    }
}
