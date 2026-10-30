import AppKit

enum NoirError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct MediaSource: Codable, Equatable, Identifiable {
    var id = UUID()
    var url: URL
    var title: String
    var disc: Bool = false
    var duration: Double = 0
    var detail: String { disc ? "Optical disc / folder" : url.isFileURL ? url.deletingLastPathComponent().lastPathComponent : url.host ?? "Network stream" }
    var kind: String { disc ? "DISC" : url.isFileURL ? url.pathExtension.uppercased() : "STREAM" }
    init(_ url: URL, title: String? = nil, disc: Bool = false) {
        // A bare "https://host/" has the path component "/", which is not a title.
        let name = url.deletingPathExtension().lastPathComponent
        self.url = url; self.title = title ?? (name == "/" ? "" : name)
        self.disc = disc || ["dvd","bluray"].contains(url.scheme?.lowercased() ?? "")
        if self.title.isEmpty { self.title = url.host ?? "Network stream" }
    }
    /// Queue identity. URL equality is textual, so a folder with and without a trailing slash would otherwise differ.
    var identity: String { disc ? playbackURL.absoluteString : url.isFileURL ? url.standardizedFileURL.path : url.absoluteString }
    var playbackURL: URL {
        guard disc else { return url }
        if ["dvd","bluray"].contains(url.scheme?.lowercased() ?? "") { return url }
        let root = url.lastPathComponent.uppercased() == "VIDEO_TS" || url.lastPathComponent.uppercased() == "BDMV" ? url.deletingLastPathComponent() : url
        let bluray = FileManager.default.fileExists(atPath: root.appendingPathComponent("BDMV").path)
        var parts = URLComponents(); parts.scheme = bluray ? "bluray" : "dvd"; parts.host = ""; parts.path = root.path
        return parts.url ?? url
    }
    var localDiscURL: URL? {
        guard disc else { return nil }
        if url.isFileURL { return url }
        guard ["dvd","bluray"].contains(url.scheme?.lowercased() ?? ""),url.host == nil || url.host == "",url.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath:url.path)
    }
}
extension MediaSource {
    // Tolerant decoding: only the URL is required, so older or partial records survive.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        self.init(try c.decode(URL.self,forKey:.url),title:try? c.decodeIfPresent(String.self,forKey:.title),disc:(try? c.decodeIfPresent(Bool.self,forKey:.disc)) ?? false)
        if let id = try? c.decodeIfPresent(UUID.self,forKey:.id) { self.id = id }
        if let value = try? c.decodeIfPresent(Double.self,forKey:.duration), value.isFinite, value >= 0 { duration = value }
    }
}
/// Decodes one array element without letting a bad element discard the whole array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) { value = try? Value(from:decoder) }
}
struct Preferences: Codable {
    static let rates = [0.5,0.75,0.9,1.0,1.25,1.5,2.0]
    var volume = 82.0, rate = 1.0
    var muted = false, rememberPosition = true, autoPlayNext = true, hardwareDecoding = true
    var preferNative = true, alwaysOnTop = false, shuffle = false
    var repeatMode = 0
    var recents: [MediaSource] = []
    var positions: [String: Double] = [:]
    var positionOrder: [String] = []
    var aacsLibrary = ""
    var snapshotFolder = ""
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["NOIR_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoirMediaPlayer")
    }
    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")), let p = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return p
    }
    func save() {
        do { try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.directory.appendingPathComponent("settings.json"), options: .atomic)
        } catch { NSLog("NOIR settings: %@", error.localizedDescription) }
    }
    mutating func bookmark(_ source: MediaSource, time: Double, duration: Double) {
        guard rememberPosition, time.isFinite, duration.isFinite, !source.disc else { return }
        let key = source.url.absoluteString
        if time > 5 && (duration <= 0 || time < duration - 5) { positions[key] = time } else { positions.removeValue(forKey: key) }
        positionOrder.removeAll { $0 == key }; positionOrder.append(key)
        while positionOrder.count > 500 { positions.removeValue(forKey: positionOrder.removeFirst()) }
    }
    var snapshots: URL {
        snapshotFolder.isEmpty ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Noir Snapshots") : URL(fileURLWithPath: snapshotFolder)
    }
}
extension Preferences {
    // Synthesized decoding requires every key, so one added field would reset all settings,
    // bookmarks and recents. Missing or malformed keys keep their defaults; values are clamped.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys,_ value: inout T) { if let decoded = try? c.decodeIfPresent(T.self,forKey:key) { value = decoded } }
        read(.volume,&volume); read(.rate,&rate); read(.muted,&muted); read(.rememberPosition,&rememberPosition)
        read(.autoPlayNext,&autoPlayNext); read(.hardwareDecoding,&hardwareDecoding); read(.preferNative,&preferNative)
        read(.alwaysOnTop,&alwaysOnTop); read(.shuffle,&shuffle); read(.repeatMode,&repeatMode)
        read(.positions,&positions); read(.positionOrder,&positionOrder); read(.aacsLibrary,&aacsLibrary); read(.snapshotFolder,&snapshotFolder)
        if let list = try? c.decodeIfPresent([Lossy<MediaSource>].self,forKey:.recents) { recents = Array(list.compactMap(\.value).prefix(30)) }
        volume = volume.isFinite ? min(100,max(0,volume)) : 82
        if !Self.rates.contains(rate) { rate = 1 }
        if !(0...2).contains(repeatMode) { repeatMode = 0 }
        positions = positions.filter { $0.value.isFinite && $0.value > 0 }
    }
}
struct TrackChoice: Equatable { let id: Int; let title: String }
struct PlaybackInfo {
    var status = "Ready", time = 0.0, duration = 0.0
    var playing = false, ended = false, failed = false, ready = false
    var size = CGSize.zero
    var audio: [TrackChoice] = [], subtitles: [TrackChoice] = []
    var audioID = -1, subtitleID = -1, chapter = -1, chapters = 0
}
enum SourceReader {
    static let extensions: Set<String> = ["mp4","m4v","mov","mkv","avi","wmv","webm","mpg","mpeg","m2ts","mts","ts","vob","ogv","3gp","asf","flv","mp3","m4a","aac","wav","aiff","aif","flac","ogg","opus","wma","ac3","ape"]
    static let captions: Set<String> = ["srt","vtt","webvtt","ass","ssa","sub","idx"]
    static let limit = 20_000
    static func sources(_ urls: [URL]) throws -> [MediaSource] {
        var result: [MediaSource] = []
        // The limit applies to the whole request, not to each folder or playlist.
        for url in urls {
            guard result.count < limit else { break }
            guard url.isFileURL else { result.append(MediaSource(url)); continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if directory.boolValue {
                if isDisc(url) { result.append(MediaSource(url, disc: true)); continue }
                let enumeration = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles,.skipsPackageDescendants])
                var files: [URL] = []
                while let file = enumeration?.nextObject() as? URL {
                    if files.count >= limit-result.count { break }
                    if let values = try? file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true, extensions.contains(file.pathExtension.lowercased()) { files.append(file) }
                }
                result += files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { MediaSource($0) }
            } else if ["m3u","m3u8"].contains(url.pathExtension.lowercased()) {
                result += try playlist(url).prefix(limit-result.count)
            } else if url.lastPathComponent.uppercased() == "VIDEO_TS.IFO" { result.append(MediaSource(url.deletingLastPathComponent(),disc:true)) }
            else { result.append(MediaSource(url)) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.identity).inserted }
    }
    static func isDisc(_ u: URL) -> Bool {
        ["VIDEO_TS","BDMV"].contains(u.lastPathComponent.uppercased()) || FileManager.default.fileExists(atPath:u.appendingPathComponent("VIDEO_TS").path) || FileManager.default.fileExists(atPath:u.appendingPathComponent("BDMV").path)
    }
    static func playlist(_ url: URL) throws -> [MediaSource] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? Int ?? 0) <= 8_388_608 else { throw NoirError.message("Playlist exceeds 8 MB.") }
        // .m3u predates UTF-8 and is often Windows-1252; .m3u8 files from Windows often carry a BOM.
        let data = try Data(contentsOf: url)
        var text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.windowsCP1252) ?? String(decoding:data,as:UTF8.self)
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        // HLS manifests describe a single streaming source, not queue entries.
        if text.contains("#EXT-X-") { return [MediaSource(url)] }
        var title: String?, sources: [MediaSource] = []
        for raw in text.components(separatedBy:.newlines) {
            let line = raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:"), let comma = line.firstIndex(of:",") { title = String(line[line.index(after:comma)...]); continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let u: URL
            if let absolute = URL(string:line), let scheme = absolute.scheme, ["http","https","rtsp","rtp","udp","file","dvd","bluray"].contains(scheme.lowercased()) { u = absolute }
            else { u = URL(fileURLWithPath:line,relativeTo:url.deletingLastPathComponent()).standardizedFileURL }
            sources.append(MediaSource(u,title:title,disc:u.isFileURL && isDisc(u))); title = nil
            if sources.count >= limit { break }
        }
        return sources
    }
    static func playlistText(_ sources: [MediaSource]) -> String {
        "#EXTM3U\n" + sources.map { "#EXTINF:-1,\($0.title.replacingOccurrences(of:"\n",with:" "))\n\($0.playbackURL.absoluteString)" }.joined(separator:"\n") + "\n"
    }
}
struct CaptionCue { let start: Double, end: Double, text: String }
struct CaptionFile {
    let url: URL; let cues: [CaptionCue]
    init(_ url: URL) throws {
        self.url = url
        guard ["srt","vtt","webvtt"].contains(url.pathExtension.lowercased()) else { throw NoirError.message("This caption format needs compatibility playback.") }
        let size = try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? Int ?? 0
        guard size <= 4_194_304 else { throw NoirError.message("Large caption files need compatibility playback.") }
        let normalized = try String(contentsOf:url,encoding:.utf8).replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\u{feff}",with:"")
        // Blank-looking separator lines may contain spaces; without this, adjacent cues merge.
        let raw = normalized.components(separatedBy:"\n").map { $0.trimmingCharacters(in:.whitespaces).isEmpty ? "" : $0 }.joined(separator:"\n")
        var parsed: [CaptionCue] = []
        for block in raw.components(separatedBy:"\n\n") {
            let lines = block.components(separatedBy:"\n")
            if block.hasPrefix("WEBVTT") || block.hasPrefix("NOTE") || block.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { continue }
            guard let row = lines.firstIndex(where: { $0.contains("-->") }) else { throw NoirError.message("Styled captions need compatibility playback.") }
            let times = lines[row].components(separatedBy:"-->").map { $0.trimmingCharacters(in:.whitespaces) }
            guard times.count == 2, let start = Self.seconds(times[0]), let end = Self.seconds(times[1]), end > start else { throw NoirError.message("Positioned captions need compatibility playback.") }
            let text = lines.dropFirst(row+1).joined(separator:"\n").trimmingCharacters(in:.newlines)
            // Preserve complex/positioned subtitle behavior by handing off the original.
            if text.contains("<") || text.contains("{") { throw NoirError.message("Formatted captions need compatibility playback.") }
            parsed.append(CaptionCue(start:start,end:end,text:text.replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">").replacingOccurrences(of:"&amp;",with:"&")))
            if parsed.count > 50_000 { throw NoirError.message("Large captions need compatibility playback.") }
        }
        guard !parsed.isEmpty else { throw NoirError.message("No caption cues found.") }
        cues = parsed.sorted { $0.start < $1.start }
    }
    static func seconds(_ value: String) -> Double? {
        let parts = value.replacingOccurrences(of:",",with:".").components(separatedBy:":")
        guard (2...3).contains(parts.count), parts.allSatisfy({ Double($0) != nil }) else { return nil }
        let values = parts.compactMap(Double.init)
        guard values.allSatisfy({ $0 >= 0 && $0.isFinite }), values.last! < 60, values[values.count-2] < 60 else { return nil }
        return values.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60,Double($1.offset)) }
    }
    func text(at seconds: Double) -> String { cues.filter { $0.start <= seconds && $0.end > seconds }.map(\.text).joined(separator:"\n") }
}
func clockText(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "0:00" }
    let t = Int(min(value,Double(Int32.max)))
    return t >= 3600 ? String(format:"%d:%02d:%02d",t/3600,t/60%60,t%60) : String(format:"%d:%02d",t/60,t%60)
}
