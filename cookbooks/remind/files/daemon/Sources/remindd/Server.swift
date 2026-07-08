import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import Logging

// Constant-time comparison of two SHA-256 digests (fixed 32 bytes) — no length
// or content timing leak, and only the hash of the token lives in memory.
func digestEquals(_ a: SHA256.Digest, _ b: SHA256.Digest) -> Bool {
    let ab = Array(a)
    let bb = Array(b)
    var diff: UInt8 = 0
    for i in 0..<32 { diff |= ab[i] ^ bb[i] }
    return diff == 0
}

private func shaPrefix(_ s: String) -> String {
    let hex = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(8))
}

// Custom context to cap the request body (default is 2 MiB; a reminder is tiny).
struct AppRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    init(source: Source) { self.coreContext = .init(source: source) }
    var maxUploadSize: Int { 64 * 1024 }
}

struct BearerAuthMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext
    let expected: SHA256.Digest

    init(token: String) { self.expected = SHA256.hash(data: Data(token.utf8)) }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        func reject(_ reason: String, presented: String? = nil) throws -> Never {
            // Log the reject reason (never the token/body). Include only a hash prefix.
            var meta: Logger.Metadata = ["reason": .string(reason), "path": .string(request.uri.path)]
            if let p = presented { meta["token_sha_prefix"] = .string(shaPrefix(p)) }
            context.logger.warning("auth rejected", metadata: meta)
            throw HTTPError(.unauthorized, message: "unauthorized")
        }

        // Require exactly one Authorization header (duplicate = differential-parsing risk).
        let authFields = request.headers.filter { $0.name == .authorization }
        guard authFields.count == 1 else {
            try reject(authFields.isEmpty ? "missing_header" : "multiple_headers")
        }
        let parts = authFields[0].value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { try reject("bad_scheme") }
        let presented = parts[1].trimmingCharacters(in: .whitespaces)
        guard !presented.isEmpty else { try reject("empty_token") }
        guard digestEquals(SHA256.hash(data: Data(presented.utf8)), expected) else {
            try reject("bad_token", presented: presented)
        }
        return try await next(request, context)
    }
}

struct CreateReminderRequest: Decodable {
    let title: String
    let list: String?
    let notes: String?
    let due: String?
    let priority: Int?
    let url: String?
}

struct CreateReminderResponse: ResponseEncodable {
    let id: String
    let title: String
    let list: String
}

struct ListsResponse: ResponseEncodable {
    let lists: [String]
}

func buildRouter(token: String, reminders: Reminders) -> Router<AppRequestContext> {
    let router = Router(context: AppRequestContext.self)

    // Liveness — intentionally unauthenticated, does zero work, leaks no state.
    router.get("healthz") { _, _ in "ok" }

    // Everything under /v1 requires the bearer token (structural group gate).
    let v1 = router.group("v1").add(middleware: BearerAuthMiddleware(token: token))

    v1.get("lists") { _, _ -> ListsResponse in
        ListsResponse(lists: await reminders.lists())
    }

    v1.post("reminders") { request, context -> EditedResponse<CreateReminderResponse> in
        let body: CreateReminderRequest
        do {
            body = try await request.decode(as: CreateReminderRequest.self, context: context)
        } catch {
            // Map any decode/parse failure to 400 without echoing decoder internals.
            throw HTTPError(.badRequest, message: "invalid JSON body")
        }

        let trimmed = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HTTPError(.badRequest, message: "title is required") }
        guard trimmed.count <= 1024 else { throw HTTPError(.badRequest, message: "title too long (max 1024)") }
        // Strip control chars from the title (single-line, log/UI hygiene).
        let title = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter { $0.value >= 0x20 }))

        if let notes = body.notes, notes.count > 16384 {
            throw HTTPError(.badRequest, message: "notes too long (max 16384)")
        }
        if let list = body.list, list.count > 256 {
            throw HTTPError(.badRequest, message: "list name too long (max 256)")
        }
        if let priority = body.priority, !(0...9).contains(priority) {
            throw HTTPError(.badRequest, message: "priority out of range (0..9)")
        }
        var cleanURL: String? = nil
        if let u = body.url {
            guard u.count <= 2048, let parsed = URL(string: u),
                  let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { throw HTTPError(.badRequest, message: "url must be http(s) and <= 2048 chars") }
            cleanURL = u
        }
        // Strip NUL from notes; keep newlines/tabs (notes may be multi-line).
        let notes = body.notes.map { String(String.UnicodeScalarView($0.unicodeScalars.filter { $0.value != 0 })) }

        let input = ReminderInput(
            title: title, list: body.list, notes: notes,
            due: body.due, priority: body.priority, url: cleanURL
        )
        do {
            let created = try await reminders.create(input)
            return EditedResponse(
                status: .created,
                response: CreateReminderResponse(id: created.id, title: title, list: created.list)
            )
        } catch ReminderError.accessDenied {
            throw HTTPError(.serviceUnavailable, message: "reminders access not granted")
        } catch ReminderError.listNotFound(let available) {
            throw HTTPError(.notFound, message: "list not found (available: \(available.joined(separator: ", ")))")
        } catch ReminderError.badDue(let s) {
            throw HTTPError(.badRequest, message: "could not parse due: \(s) (ISO8601 or YYYY-MM-DD, within ~100y)")
        } catch {
            context.logger.error("create failed: \(error)")
            throw HTTPError(.internalServerError, message: "internal error")
        }
    }

    return router
}
