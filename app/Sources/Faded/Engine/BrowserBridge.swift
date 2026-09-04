// BrowserBridge.swift — Chrome tab volumes inside Faded's own menu.
//
// The Faded Tabs extension does the actual per-tab work (a browser is a single
// audio client to macOS — tabs only exist inside it). This bridge is how those
// tabs reach the menu bar:
//
//   extension ⇄ faded-native-host (spawned by Chrome) ⇄ this, over a unix
//   socket, newline-delimited JSON.
//
// Chrome insists on launching the native host itself, from a manifest at a
// fixed path — so Faded cannot connect out; it listens, and the relay dials
// in. `installManifests()` writes those manifests for every Chromium-family
// browser present, pointing at the helper inside this app bundle.
//
// Protocol (all messages are single-line JSON objects):
//   ext → app : {type:"tabs", tabs:[{id,title,gain,audible,muted}]}
//   app → ext : {type:"setGain", tabId, gain} | {type:"setMuted", tabId, muted}
//               | {type:"ping"}   (also keeps the MV3 service worker awake)
//   relay     : {type:"bridge", connected:bool} in both directions.

import Darwin
import Foundation
import os

struct BrowserTab: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    var gain: Float
    var audible: Bool
    var muted: Bool
}

/// All socket state is confined to the private serial queue; the public
/// surface is thread-safe and callbacks hop to the main actor. (Not @MainActor
/// itself — the read/accept handlers run on the queue by construction.)
final class BrowserBridge: @unchecked Sendable {
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "Bridge")

    static let hostName = "com.andri.faded"
    static let extensionID = "epggnfcikpcfaklnoljedmlbaibllofm"

    var onTabs: (@MainActor ([BrowserTab]) -> Void)?
    var onConnectionChanged: (@MainActor (Bool) -> Void)?
    private var isConnected = false   // queue-confined

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var pingTimer: Timer?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.andri.faded.bridge")

    static var socketPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bridge.sock").path
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            installManifests()
            listen()
        }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.send(["type": "ping"])
        }
    }

    func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        queue.sync {
            closeClient()
            listenSource?.cancel()
            listenSource = nil
            if listenFD >= 0 { close(listenFD) }
            listenFD = -1
        }
    }

    // MARK: Outgoing

    func setTabGain(_ tabID: Int, _ gain: Float) {
        send(["type": "setGain", "tabId": tabID, "gain": Double(min(max(gain, 0), 1))])
    }

    func setTabMuted(_ tabID: Int, _ muted: Bool) {
        send(["type": "setMuted", "tabId": tabID, "muted": muted])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        queue.async { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            var line = data
            line.append(0x0A)
            var failed = false
            line.withUnsafeBytes { buf in
                var off = 0
                while off < line.count {
                    let n = write(self.clientFD, buf.baseAddress!.advanced(by: off), line.count - off)
                    if n <= 0 { failed = true; return }
                    off += n
                }
            }
            if failed { self.closeClient() }
        }
    }

    // MARK: Socket plumbing (bridge queue)

    private func listen() {
        let path = Self.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { pathBuf in
            path.utf8CString.withUnsafeBytes { src in
                pathBuf.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(pathBuf.count - 1)))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 }
        }
        guard bound, Darwin.listen(fd, 2) == 0 else {
            close(fd)
            Self.log.error("bridge: could not bind \(path, privacy: .public)")
            Task { @MainActor in trace("bridge: could not bind \(path) errno=\(errno)") }
            return
        }
        chmod(path, 0o600)  // this socket accepts volume commands; owner only
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        listenSource = source
        Self.log.info("bridge: listening")
        Task { @MainActor in trace("bridge: listening on \(path)") }
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // One relay at a time; a newer connection replaces a stale one.
        closeClient()
        clientFD = fd
        buffer.removeAll()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient() }
        source.setCancelHandler { close(fd) }
        source.resume()
        clientSource = source
        connectionChanged(true)
    }

    private func readClient() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(clientFD, &chunk, chunk.count)
        guard n > 0 else {
            closeClient()
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { handle(line) }
        }
    }

    private func closeClient() {
        guard clientSource != nil else { return }
        clientSource?.cancel()   // its cancel handler closes the fd
        clientSource = nil
        clientFD = -1
        connectionChanged(false)
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "tabs":
            let tabs: [BrowserTab] = ((obj["tabs"] as? [[String: Any]]) ?? []).compactMap { t in
                guard let id = t["id"] as? Int else { return nil }
                return BrowserTab(id: id,
                                  title: t["title"] as? String ?? "Tab",
                                  gain: Float(t["gain"] as? Double ?? 1),
                                  audible: t["audible"] as? Bool ?? false,
                                  muted: t["muted"] as? Bool ?? false)
            }
            Self.log.info("bridge: snapshot with \(tabs.count) tab(s)")
            Task { @MainActor in trace("bridge: snapshot with \(tabs.count) tab(s)") }
            Task { @MainActor in self.onTabs?(tabs) }
        case "bridge":
            break  // relay's own status; connection state is tracked by the socket
        default:
            break
        }
    }

    /// Queue-confined bookkeeping; UI callbacks hop to the main actor.
    private func connectionChanged(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        Self.log.info("bridge: extension \(connected ? "connected" : "disconnected")")
        Task { @MainActor in trace("bridge: relay \(connected ? "connected" : "disconnected")") }
        Task { @MainActor [self] in
            if !connected { onTabs?([]) }
            onConnectionChanged?(connected)
        }
    }

    // MARK: Native-messaging host manifests

    /// Chrome finds native hosts by a JSON manifest at a fixed per-browser
    /// path. Written on every launch: it is idempotent, and it self-heals when
    /// the app moves or the helper changes.
    private func installManifests() {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/faded-native-host")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            Self.log.error("bridge: helper missing from the app bundle — build with make")
            return
        }

        let manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "Faded browser tab volume bridge",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Every Chromium-family data dir that exists gets one; missing browsers
        // are skipped rather than having empty directories invented for them.
        let browserDirs = [
            "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary",
            "BraveSoftware/Brave-Browser", "Microsoft Edge", "Chromium", "Arc/User Data",
        ]
        for dir in browserDirs {
            let base = appSupport.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            let hostsDir = base.appendingPathComponent("NativeMessagingHosts")
            try? FileManager.default.createDirectory(at: hostsDir, withIntermediateDirectories: true)
            let file = hostsDir.appendingPathComponent("\(Self.hostName).json")
            if (try? Data(contentsOf: file)) != data {
                try? data.write(to: file)
                Self.log.info("bridge: manifest installed for \(dir, privacy: .public)")
            }
        }
    }
}
