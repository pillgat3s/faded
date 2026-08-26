// faded-native-host — the relay between Chrome and Faded.app.
//
// Chrome's native messaging works backwards from what you might expect: the
// BROWSER launches this executable (one per extension connection) and speaks
// length-prefixed JSON over stdin/stdout. Faded.app cannot be that executable —
// it is a long-lived menu bar app, not a child of Chrome — so this tiny host
// exists purely to shuttle bytes between the two:
//
//   Chrome (stdio, uint32-LE length + JSON)  ⇄  this  ⇄  Faded.app
//                                            (unix socket, newline JSON)
//
// Lifecycle: lives as long as the extension keeps its port open. If Faded.app
// is not running, the socket connect fails and is retried every few seconds —
// the port to Chrome stays open, so the extension does not need its own retry
// dance for app restarts. Chrome closing stdin ends the process.
//
// Kept dependency-free (Foundation only) and single-file so `make` can build
// it straight into Faded.app/Contents/Helpers.

import Foundation

let socketPath = ("~/Library/Application Support/Faded/bridge.sock" as NSString)
    .expandingTildeInPath

// MARK: - Chrome framing (stdin/stdout)

/// Reads one length-prefixed message from stdin. Nil on EOF (Chrome is gone).
func readChromeMessage() -> Data? {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    var got = 0
    while got < 4 {
        let n = read(0, &lengthBytes[got], 4 - got)
        if n <= 0 { return nil }
        got += n
    }
    let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    guard length > 0, length < 4 * 1024 * 1024 else { return nil }
    var body = Data(count: Int(length))
    var read0 = 0
    while read0 < Int(length) {
        let n = body.withUnsafeMutableBytes { buf in
            read(0, buf.baseAddress!.advanced(by: read0), Int(length) - read0)
        }
        if n <= 0 { return nil }
        read0 += n
    }
    return body
}

let stdoutLock = NSLock()
func writeChromeMessage(_ data: Data) {
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    var length = UInt32(data.count).littleEndian
    withUnsafeBytes(of: &length) { _ = write(1, $0.baseAddress, 4) }
    data.withUnsafeBytes { buf in
        var off = 0
        while off < data.count {
            let n = write(1, buf.baseAddress!.advanced(by: off), data.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}

// MARK: - Socket to Faded.app (newline JSON)

final class AppLink {
    private var fd: Int32 = -1
    private let lock = NSLock()

    /// Sends one JSON message; silently drops if the app is not connected
    /// (the extension re-sends its snapshot on every ping, so nothing is lost
    /// for long).
    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        var line = data
        line.append(0x0A)
        let ok = line.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < line.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), line.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if !ok { closeLocked() }
    }

    private func closeLocked() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Connect-and-read loop. Runs forever on its own thread; each connection
    /// failure notifies the extension and retries.
    func run() {
        var announcedDown = false
        while true {
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { pathBuf in
                socketPath.utf8CString.withUnsafeBytes { src in
                    pathBuf.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(pathBuf.count - 1)))
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, len) == 0 }
            }
            if !connected {
                close(sock)
                if !announcedDown {
                    announcedDown = true
                    writeChromeMessage(Data(#"{"type":"bridge","connected":false}"#.utf8))
                }
                Thread.sleep(forTimeInterval: 3)
                continue
            }

            lock.lock(); fd = sock; lock.unlock()
            announcedDown = false
            writeChromeMessage(Data(#"{"type":"bridge","connected":true}"#.utf8))

            // Read newline-delimited JSON from the app, forward each to Chrome.
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            readLoop: while true {
                let n = read(sock, &chunk, chunk.count)
                if n <= 0 { break readLoop }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if !line.isEmpty { writeChromeMessage(line) }
                }
            }
            lock.lock(); closeLocked(); lock.unlock()
        }
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
let link = AppLink()
Thread.detachNewThread { link.run() }

// Chrome → app, on the main thread. EOF means Chrome closed the port: exit.
while let message = readChromeMessage() {
    link.send(message)
}
exit(0)
