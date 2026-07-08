import Foundation
import Hummingbird
import Logging

// remindd — HTTP daemon that creates macOS Reminders from network requests.
// Usage: remindd serve [--bind HOST] [--port N]
// Reachability/security is LAN + bearer token (see cookbooks/remind/README.md).

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "serve" else {
    FileHandle.standardError.write("usage: remindd serve [--bind HOST] [--port N]\n".data(using: .utf8)!)
    exit(1)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let env = ProcessInfo.processInfo.environment
var bind = env["REMIND_BIND"] ?? "0.0.0.0"
var port = Int(env["REMIND_PORT"] ?? "") ?? 8787
var i = 1
while i < args.count {
    switch args[i] {
    case "--bind": i += 1; if i < args.count { bind = args[i] }
    case "--port": i += 1; if i < args.count { port = Int(args[i]) ?? port }
    default: break
    }
    i += 1
}

// Token — fail CLOSED. A missing/empty/short/world-readable token must not
// start an open server.
let tokenPath = env["REMIND_TOKEN_FILE"] ?? "~/.config/remind/token"
let expandedTokenPath = (tokenPath as NSString).expandingTildeInPath
guard let rawToken = try? String(contentsOfFile: expandedTokenPath, encoding: .utf8) else {
    fail("token file not readable: \(expandedTokenPath)")
}
// Refuse a group/other-readable token file (catches the 0644 generation race).
if let perms = (try? FileManager.default.attributesOfItem(atPath: expandedTokenPath))?[.posixPermissions] as? NSNumber,
   perms.intValue & 0o077 != 0 {
    fail("token file \(expandedTokenPath) is group/other-accessible (chmod 600 it)")
}
let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
guard token.count >= 32, token.allSatisfy({ $0.isHexDigit }) else {
    fail("token in \(expandedTokenPath) must be >= 32 hex chars (openssl rand -hex 32)")
}

var logger = Logger(label: "remindd")
logger.logLevel = .info

// Request Reminders access up front. If denied, keep serving (so launchd does
// not enter a crash-restart loop) but create endpoints return 503 until granted.
let reminders = Reminders()
let granted = await reminders.requestAccess()
if !granted {
    logger.warning("Reminders full access NOT granted — create endpoints return 503 until granted (System Settings > Privacy & Security > Reminders)")
}

let router = buildRouter(token: token, reminders: reminders)
let app = Application(
    router: router,
    configuration: .init(address: .hostname(bind, port: port), serverName: "remindd"),
    logger: logger
)
logger.info("remindd listening", metadata: ["bind": .string(bind), "port": .stringConvertible(port), "reminders_access": .stringConvertible(granted)])
try await app.runService()
