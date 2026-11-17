// A minimal sandboxed app that starts the Free P2P engine the way Orvix does:
// as a child process, from Contents/Resources, with a working directory in
// the sandbox's temporary folder. It answers one question that cannot be
// answered by running the engine on its own: does the engine start and serve
// inside the macOS App Sandbox, with the entitlements Orvix ships?
//
// Built and run by tools/macos_sandbox_engine_test.sh. Exit status 0 means
// the engine answered its health check from inside the sandbox.
//
// With ORVIX_PROBE_MAGNET set it then also asks the engine for the first
// bytes of a file in that torrent. That part needs peers on the public
// network, so it only reports what happened and never changes the status.
import Foundation

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

final class Reply: @unchecked Sendable {
    var status = 0
    var data = Data()
}

func request(_ url: String, method: String = "GET", body: Data? = nil,
             headers: [String: String] = [:], timeout: TimeInterval = 5) -> (Int, Data) {
    guard let target = URL(string: url) else { return (0, Data()) }
    var request = URLRequest(url: target)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = timeout
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let done = DispatchSemaphore(value: 0)
    let reply = Reply()
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        reply.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        reply.data = data ?? Data()
        done.signal()
    }
    task.resume()
    if done.wait(timeout: .now() + timeout + 2) == .timedOut {
        task.cancel()
        return (0, Data())
    }
    return (reply.status, reply.data)
}

let environment = ProcessInfo.processInfo.environment
let container = environment["APP_SANDBOX_CONTAINER_ID"] ?? ""
guard !container.isEmpty else {
    say("FAIL: this process is not sandboxed, so the test would prove nothing.")
    exit(2)
}
say("Sandbox container: \(container)")
say("Home inside the sandbox: \(NSHomeDirectory())")

let engine = Bundle.main.resourceURL!.appendingPathComponent("orvix-stream-server")
let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("Orvix").appendingPathComponent("torrent-engine")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let log = work.appendingPathComponent("engine.log")
FileManager.default.createFile(atPath: log.path, contents: nil)

let port = environment["ORVIX_PROBE_PORT"] ?? "11494"
let base = "http://127.0.0.1:\(port)"
let process = Process()
process.executableURL = engine
process.arguments = ["--no-tray"]
process.currentDirectoryURL = work
var child = environment
child["ORVIX_STREAM_SERVER_PORT"] = port
process.environment = child
let output = try? FileHandle(forWritingTo: log)
process.standardOutput = output
process.standardError = output

func fail(_ reason: String) -> Never {
    say("FAIL: \(reason)")
    if let text = try? String(contentsOf: log, encoding: .utf8) {
        say("--- engine output")
        say(String(text.suffix(3000)))
    }
    if process.isRunning { process.terminate() }
    exit(1)
}

do { try process.run() } catch { fail("the engine could not be started: \(error)") }
say("Engine started as a child process (pid \(process.processIdentifier)).")

var ready = false
for _ in 0..<120 {
    if request("\(base)/heartbeat", timeout: 2).0 == 200 { ready = true; break }
    if !process.isRunning { fail("the engine exited with status \(process.terminationStatus).") }
    Thread.sleep(forTimeInterval: 0.5)
}
if !ready { fail("the engine did not answer its health check within 60 s.") }
say("Health check answered on \(base) from inside the sandbox.")

let (settingsStatus, settings) = request("\(base)/settings")
if settingsStatus == 200,
   let json = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any] {
    let values = (json["values"] as? [String: Any]) ?? json
    if let cache = values["cacheRoot"] {
        say("Engine cache folder: \(cache)")
    }
}

if let magnet = environment["ORVIX_PROBE_MAGNET"], !magnet.isEmpty,
   let hashRange = magnet.range(of: "btih:") {
    let hash = String(magnet[hashRange.upperBound...].prefix(40)).lowercased()
    say("--- Network test (public torrent \(hash.prefix(8))…; informational)")
    let body: [String: Any] = ["from": magnet, "guessFileIdx": [String: Any]()]
    let create = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    let (createStatus, created) = request("\(base)/create", method: "POST", body: create,
                                          headers: ["Content-Type": "application/json"],
                                          timeout: 90)
    say("Torrent added: HTTP \(createStatus)")
    var index = 0
    if let json = (try? JSONSerialization.jsonObject(with: created)) as? [String: Any],
       let guessed = json["guessedFileIdx"] as? Int, guessed >= 0 {
        index = guessed
    }
    var bytes = 0
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline && bytes == 0 {
        let (status, data) = request("\(base)/\(hash)/\(index)",
                                     headers: ["Range": "bytes=0-262143"], timeout: 30)
        if status == 200 || status == 206 { bytes = data.count }
        if bytes == 0 { Thread.sleep(forTimeInterval: 3) }
    }
    if bytes > 0 {
        say("Network test: the engine served \(bytes) bytes of media over HTTP.")
    } else {
        say("Network test: no media bytes within 2 minutes (no peers reachable from here).")
    }
    _ = request("\(base)/\(hash)/remove")
}

process.terminate()
process.waitUntilExit()
say("Engine stopped. Sandbox test passed.")
exit(0)
