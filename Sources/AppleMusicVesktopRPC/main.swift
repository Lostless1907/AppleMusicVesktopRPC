import Foundation
import Darwin

private let appID = ProcessInfo.processInfo.environment["APPLE_MUSIC_RPC_APP_ID"] ?? "1565358520541519912"
private let pollInterval: TimeInterval = 3

struct Track: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let playing: Bool

    var key: String { "\(title)\u{1f}\(artist)\u{1f}\(album)" }
}

func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    print("[\(formatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

func currentTrack() -> Track? {
    let script = #"""
    tell application "Music"
        if player state is stopped then return ""
        try
            set t to current track
            set trackName to name of t as text
            set trackArtist to artist of t as text
            set trackAlbum to album of t as text
            set trackDuration to duration of t
            set trackPosition to player position
            set stateText to player state as text
            return trackName & (character id 31) & trackArtist & (character id 31) & trackAlbum & (character id 31) & (trackDuration as text) & (character id 31) & (trackPosition as text) & (character id 31) & stateText
        on error
            return ""
        end try
    end tell
    """#

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .newlines),
              !result.isEmpty else { return nil }
        let fields = result.components(separatedBy: "\u{1f}")
        guard fields.count >= 6 else { return nil }
        let state = fields[5].lowercased()
        return Track(
            title: fields[0], artist: fields[1], album: fields[2],
            duration: Double(fields[3]) ?? 0,
            position: Double(fields[4]) ?? 0,
            playing: state == "playing"
        )
    } catch {
        log("Could not query Music.app: \(error.localizedDescription)")
        return nil
    }
}

func artworkURL(for track: Track) async -> String? {
    var components = URLComponents(string: "https://itunes.apple.com/search")
    components?.queryItems = [
        URLQueryItem(name: "term", value: "\(track.artist) \(track.album) \(track.title)"),
        URLQueryItem(name: "entity", value: "song"),
        URLQueryItem(name: "limit", value: "5"),
        URLQueryItem(name: "country", value: "us")
    ]
    guard let url = components?.url else { return nil }
    do {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }

        let normalizedTitle = track.title.lowercased()
        let normalizedArtist = track.artist.lowercased()
        let match = results.first { item in
            let title = (item["trackName"] as? String ?? "").lowercased()
            let artist = (item["artistName"] as? String ?? "").lowercased()
            return title == normalizedTitle && artist == normalizedArtist
        } ?? results.first

        guard let raw = match?["artworkUrl100"] as? String else { return nil }
        return raw
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "100x100", with: "600x600")
    } catch {
        log("Artwork lookup failed: \(error.localizedDescription)")
        return nil
    }
}

final class DiscordIPC {
    private var fd: Int32 = -1
    private var socketPath: String?
    var isConnected: Bool { fd >= 0 }

    deinit { disconnect() }

    func disconnect() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private func writeAll(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return false }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func readExact(_ count: Int) -> Data? {
        var result = Data(count: count)
        let ok = result.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var received = 0
            while received < count {
                let n = Darwin.read(fd, base.advanced(by: received), count - received)
                if n <= 0 { return false }
                received += n
            }
            return true
        }
        return ok ? result : nil
    }

    private func sendFrame(opcode: UInt32, payload: Data) -> Bool {
        var header = Data()
        var op = opcode.littleEndian
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &op) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(payload)
        return writeAll(header)
    }

    private func receiveFrame() -> (UInt32, Data)? {
        guard let header = readExact(8) else { return nil }
        let opcode = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let length = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
        guard length <= 1_048_576, let body = readExact(Int(length)) else { return nil }
        return (opcode, body)
    }

    func connect() -> Bool {
        disconnect()
        let path = (ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()) + "discord-ipc-0"
        socketPath = path
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= maxPath else { Darwin.close(socketFD); return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for i in 0..<pathBytes.count { buffer[i] = UInt8(bitPattern: pathBytes[i]) }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, addressLength)
            }
        }
        guard connected == 0 else {
            Darwin.close(socketFD)
            return false
        }
        fd = socketFD

        // Prevent a broken/mismatched socket from hanging the client forever.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let handshake: [String: Any] = ["v": 1, "client_id": appID]
        guard let data = try? JSONSerialization.data(withJSONObject: handshake),
              sendFrame(opcode: 0, payload: data),
              receiveFrame() != nil else {
            log("IPC handshake failed; check Vesktop's built-in arRPC setting.")
            disconnect()
            return false
        }
        log("Connected to Vesktop IPC at \(path)")
        return true
    }

    func setActivity(track: Track, artwork: String?) -> Bool {
        var activity: [String: Any] = [
            "type": 2,
            "details": track.title,
            "state": track.artist,
            "assets": ["large_text": track.album]
        ]
        if let artwork { activity["assets"] = ["large_image": artwork, "large_text": track.album] }
        if track.duration > 0 {
            let start = Int(Date().timeIntervalSince1970 - track.position)
            activity["timestamps"] = ["start": start]
        }
        let args: [String: Any] = ["pid": getpid(), "activity": activity]
        let packet: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]
        guard let data = try? JSONSerialization.data(withJSONObject: packet) else { return false }
        return sendFrame(opcode: 1, payload: data)
    }

    func clearActivity() -> Bool {
        let packet: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": getpid(), "activity": NSNull()],
            "nonce": UUID().uuidString
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: packet) else { return false }
        return sendFrame(opcode: 1, payload: data)
    }
}

@main
struct AppleMusicVesktopRPC {
    static func main() async {
        log("Apple Music → Vesktop RPC starting (application ID: \(appID))")
        log("Grant Music.app automation permission if macOS asks.")
        let rpc = DiscordIPC()
        var lastKey: String?
        var lastPublishedKey: String?
        var lastPlaying = false
        var lastArtwork: String?
        var lastArtworkKey: String?

        while true {
            guard let track = currentTrack(), track.playing else {
                if lastPlaying {
                    _ = rpc.clearActivity()
                    log("Playback stopped; activity cleared.")
                }
                lastPlaying = false
                lastKey = nil
                try? await Task.sleep(for: .seconds(pollInterval))
                continue
            }

            var justConnected = false
            if !lastPlaying || !rpc.isConnected {
                if !rpc.connect() {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                justConnected = true
            }

            if track.key != lastKey {
                log("Now playing: \(track.title) — \(track.artist)")
                lastArtwork = await artworkURL(for: track)
                lastArtworkKey = track.key
                if let lastArtwork { log("Found album artwork.") }
                else { log("No artwork match found; publishing text-only activity.") }
                lastKey = track.key
            }

            if justConnected || lastPublishedKey != track.key {
                if rpc.setActivity(track: track, artwork: lastArtwork) {
                    lastPublishedKey = track.key
                } else {
                    log("IPC write failed; reconnecting.")
                    rpc.disconnect()
                }
            }
            lastPlaying = true
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

}
