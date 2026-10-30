import AppKit
private final class PointerProbeView: NSView {
    var moves = 0
    var point = NSPoint.zero
    override func mouseMoved(with event: NSEvent) { moves += 1; point = convert(event.locationInWindow,from:nil) }
}
// Deterministic integration checks are invoked only with --smoke-test <fixture directory>.
final class SmokeRunner {
    weak var app: AppDelegate?
    let directory: URL
    init(app: AppDelegate,directory: URL) { self.app = app; self.directory = directory }
    var checks: [[String:Any]] = []
    var cleanup: (()->Void)?
    func check(_ name: String,_ passed: Bool,_ detail: String = "") { checks.append(["check":name,"passed":passed,"detail":detail]); NSLog("NOIR check %@: %@ %@",name,passed ? "PASS" : "FAIL",detail) }
    func delay(_ seconds: Double = 0.8,_ action: @escaping ()->Void) { DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:action) }
    func until(_ name: String,timeout: Double = 12,condition: @escaping ()->Bool,then: @escaping ()->Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { self.check(name,true); then() }
            else if Date() > deadline { self.check(name,false,self.app?.hub.info.status ?? "No app"); self.finish() }
            else { self.delay(0.2,poll) }
        }; poll()
    }
    func start() {
        guard let app else { return }
        for name in ["native-snapshot.png","vlc-snapshot.png","smoke-report.json"] { try? FileManager.default.removeItem(at:directory.appendingPathComponent(name)) }
        app.preferences.autoPlayNext = false; app.preferences.rememberPosition = false; app.preferences.preferNative = true; app.preferences.muted = true
        app.preferences.shuffle = false; app.preferences.repeatMode = 0; app.preferences.rate = 1
        app.preferences.snapshotFolder = directory.path; app.preferences.positions = [:]
        do {
            let playlist = directory.appendingPathComponent("roundtrip.m3u8")
            let original = [MediaSource(directory.appendingPathComponent("native.mp4"),title:"Unicode café 日本語"),MediaSource(URL(string:"https://example.com/film.mp4")!)]
            try SourceReader.playlistText(original).write(to:playlist,atomically:true,encoding:.utf8)
            let parsed = try SourceReader.playlist(playlist)
            check("playlist round trip",parsed.map(\.url) == original.map(\.url) && parsed[0].title == original[0].title)
            for (folder,scheme) in [("VIDEO_TS","dvd"),("BDMV","bluray")] {
                let root = directory.appendingPathComponent("disc-\(scheme)")
                try FileManager.default.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true)
                let disc = MediaSource(root,title:"Test \(scheme)",disc:true)
                try SourceReader.playlistText([disc]).write(to:playlist,atomically:true,encoding:.utf8)
                let restored = try SourceReader.playlist(playlist)[0]
                check("\(scheme) playlist retains disc identity",restored.disc && restored.title == disc.title && restored.playbackURL == disc.playbackURL && restored.localDiscURL?.path == root.path && restored.identity == disc.identity)
                try ("#EXTM3U\n"+root.absoluteString+"\n").write(to:playlist,atomically:true,encoding:.utf8)
                check("legacy \(scheme) folder playlist",try SourceReader.playlist(playlist)[0].playbackURL.scheme == scheme)
                var unmounted = false
                let ejector = DiscEjector(unmount:{ _ in unmounted = true })
                check("\(scheme) folder on non-optical storage cannot eject",ejector.target(for:disc) == nil && !unmounted)
            }
            let remoteDisc = MediaSource(URL(string:"dvd://remote.example/Volumes/DVD")!)
            check("remote disc cannot target local storage",remoteDisc.localDiscURL == nil)
            let optical = OpticalDevice(volume:directory,bsdName:"synthetic-optical",registryID:1)
            var requests: [OpticalDevice] = []
            let ejector = DiscEjector(inspect:{ _ in optical },unmount:{ requests.append($0) })
            try ejector.eject(optical)
            check("verified optical device reaches eject adapter",requests == [optical])
            requests = []
            let changed = DiscEjector(inspect:{ _ in OpticalDevice(volume:optical.volume,bsdName:optical.bsdName,registryID:2) },unmount:{ requests.append($0) })
            let rejected = (try? changed.eject(optical)) == nil
            check("changed optical device is not ejected",rejected && requests.isEmpty)
            let unmounted = OpticalDevice(volume:nil,bsdName:"synthetic-unmounted",registryID:3)
            let fallback = DiscEjector(inspect:{ $0 },unmount:{ requests.append($0) },available:{ [unmounted] })
            check("unmounted optical disc can be selected without active playback",fallback.targets(preferred:[]) == [unmounted])
            try fallback.eject(unmounted)
            check("unmounted optical disc reaches whole-device eject adapter",requests == [unmounted])
            let multiple = DiscEjector(available:{ [optical,unmounted] })
            check("multiple optical discs require a selection",multiple.targets(preferred:[]).count == 2)
            let partitionSource = MediaSource(URL(fileURLWithPath:"/Volumes/Test DVD"),disc:true)
            let whole = OpticalDevice(volume:nil,bsdName:"synthetic-whole",registryID:4)
            let partition = OpticalDevice(volume:partitionSource.url,bsdName:whole.bsdName,registryID:whole.registryID)
            let partitioned = DiscEjector(available:{ [whole] },locate:{ _ in partition })
            check("partitioned optical selection retains mounted volume",partitioned.targets(preferred:[partitionSource]) == [partition])
            check("partitioned optical playback is identified by whole-device identity",partitioned.contains(partitionSource,on:whole))
            check("replacement optical media cannot match playing disc",!partitioned.contains(partitionSource,on:OpticalDevice(volume:partition.volume,bsdName:whole.bsdName,registryID:5)))
            check("bundled AACS runtime loads and exports playback interface",AacsRuntime.libraryPath != nil)
            let lookup = ProcessInfo.processInfo.environment["LIBAACS_PATH"].map { $0+".dylib" }
            check("libbluray macOS lookup resolves the validated AACS library",lookup == AacsRuntime.libraryPath)
            let caption = try CaptionFile(directory.appendingPathComponent("plain.srt")); check("caption boundaries",caption.text(at:1).contains("native") && caption.text(at:12).isEmpty)
            check("complex caption routes to compatibility",(try? CaptionFile(directory.appendingPathComponent("styled.srt"))) == nil)
            for type in ["stored","deflated"] {
                let zip=try Data(contentsOf:directory.appendingPathComponent("keys-\(type).zip")); let extracted=try AacsKeys.database(zip)
                check("AACS \(type) ZIP",String(data:extracted,encoding:.utf8)?.contains("no usable keys")==true)
                check("AACS truncated \(type) ZIP rejected",(try? AacsKeys.database(Data(zip.dropLast(4))))==nil)
            }
            try modelChecks(app)
        } catch { check("fixture parsing",false,error.localizedDescription) }
        app.add([MediaSource(directory.appendingPathComponent("native.mp4"))])
        // Issued before AVFoundation is ready: the position must survive startup.
        app.hub.seek(4)
        until("AVFoundation ready",condition:{ app.hub.backend == .native && app.hub.info.ready && app.ui.video.nativeLayer.isReadyForDisplay }) {
            self.until("seek during native startup is kept",timeout:3,condition:{ app.hub.info.time >= 3.9 && app.hub.info.time < 6 }) { self.nativeControls() }
        }
    }
    func modelChecks(_ app: AppDelegate) throws {
        let container = CompatibilityVideoView(frame:NSRect(x:20,y:30,width:200,height:100))
        let renderer = PointerProbeView(frame:NSRect(x:0,y:0,width:200,height:100))
        container.addSubview(renderer); app.ui.addSubview(container)
        let location = renderer.convert(NSPoint(x:75,y:25),to:nil)
        if let click = NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:0,windowNumber:app.window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) {
            check("disc click refreshes renderer pointer at correct coordinates",container.updatePointerPosition(click) && renderer.moves == 1 && abs(renderer.point.x-75)<0.01 && abs(renderer.point.y-25)<0.01)
            container.isHidden = true
            check("hidden compatibility video does not receive disc pointer input",!container.updatePointerPosition(click) && renderer.moves == 1)
        } else { check("disc pointer test event created",false) }
        container.removeFromSuperview()
        let native = directory.appendingPathComponent("native.mp4"), plain = directory.appendingPathComponent("plain.srt")
        let keysFolder = directory.appendingPathComponent("key-validation")
        try FileManager.default.createDirectory(at:keysFolder,withIntermediateDirectories:true)
        for (kind,text) in [
            ("PK","| PK | 0x00000000000000000000000000000000\n"),
            ("DK","| DK | DEVICE_KEY 0x00000000000000000000000000000000 | DEVICE_NODE 0x0000 | KEY_UV 0x00000000000000000000000000000000 | KEY_U_MASK_SHIFT 0x00\n"),
            ("HC","| HC | HOST_PRIV_KEY 0x"+String(repeating:"0",count:40)+" | HOST_CERT 0x"+String(repeating:"0",count:184)+"\n")
        ] {
            try text.write(to:keysFolder.appendingPathComponent("KEYDB.cfg"),atomically:true,encoding:.utf8)
            check("key-only \(kind) configuration passes installed preflight",(try? AacsKeys.validateInstalled(in:keysFolder)) != nil)
        }
        for text in ["<html>| PK | server failure</html>","not a key database"] {
            try text.write(to:keysFolder.appendingPathComponent("KEYDB.cfg"),atomically:true,encoding:.utf8)
            check("invalid key configuration remains rejected",(try? AacsKeys.validateInstalled(in:keysFolder)) == nil)
        }
        check("folder identity ignores trailing slash",MediaSource(URL(string:"file:///tmp/noir-folder/")!).identity == MediaSource(URL(string:"file:///tmp/noir-folder")!).identity)
        check("network root URL title uses host",MediaSource(URL(string:"https://example.com/")!).title == "example.com")
        // Settings written by another version: missing keys keep defaults, a bad recent is dropped, values are clamped.
        let legacy = #"{"volume":500,"rate":3,"repeatMode":7,"positions":{"a":12,"b":-4},"recents":[{"url":"file:///tmp/a.mp4","title":"Kept"},{"title":"No URL"}]}"#
        let settings = try JSONDecoder().decode(Preferences.self,from:Data(legacy.utf8))
        check("settings from another version keep known values",settings.positions == ["a":12] && settings.recents.map(\.title) == ["Kept"] && settings.autoPlayNext && settings.preferNative)
        check("out-of-range settings are clamped",settings.volume == 100 && settings.rate == 1 && settings.repeatMode == 0)
        let caption = directory.appendingPathComponent("spaced.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nFirst &amp;lt;cue&amp;gt;\n \n2\n00:00:03,000 --> 00:00:04,000\nSecond\n".write(to:caption,atomically:true,encoding:.utf8)
        let cues = try CaptionFile(caption).cues
        check("whitespace-only caption separators split cues",cues.count == 2 && cues.last?.text == "Second")
        check("caption entities decode once",cues.first?.text == "First &lt;cue&gt;")
        let latin = directory.appendingPathComponent("latin1.m3u"), bom = directory.appendingPathComponent("bom.m3u8")
        try (Data("#EXTM3U\n#EXTINF:-1,Caf".utf8)+Data([0xE9])+Data("\nnative.mp4\n".utf8)).write(to:latin)
        try (Data([0xEF,0xBB,0xBF])+Data("#EXTM3U\nnative.mp4\n".utf8)).write(to:bom)
        check("Windows-1252 playlist",try SourceReader.playlist(latin).map(\.title) == ["Café"])
        check("BOM playlist has no phantom entry",try SourceReader.playlist(bom).map(\.url.lastPathComponent) == ["native.mp4"])
        let lists = ["limit-a.m3u","limit-b.m3u"].map { directory.appendingPathComponent($0) }
        for (i,list) in lists.enumerated() { try (0..<15_000).map { "missing-\(i)-\($0).mp4" }.joined(separator:"\n").write(to:list,atomically:true,encoding:.utf8) }
        check("source limit applies across inputs",try SourceReader.sources(lists).count == SourceReader.limit)
        // A 2-byte character straddling the 4 MB inspection boundary.
        var keys = Data("entry = value | test\n".utf8); keys.append(Data(repeating:0x78,count:4*1024*1024-1-keys.count)); keys.append(contentsOf:[0xC3,0xA9,0x0A])
        check("AACS key database split mid-character",(try? AacsKeys.database(keys)) != nil)
        nvlc_pause(nil,1); nvlc_seek(nil,0); nvlc_volume(nil,50,0); nvlc_rate(nil,1); nvlc_aspect(nil,nil); nvlc_chapter(nil,0); nvlc_navigate(nil,0); nvlc_track(nil,0,0)
        check("VLC adapter tolerates a missing player",nvlc_tracks(nil,0,nil,nil,0,0) == 0 && nvlc_subtitle(nil,"") != 0 && nvlc_snapshot(nil,"") != 0 && nvlc_state(nil).state == 0)
        let split = AppDelegate.splitCaptions([native,plain])
        check("dropped captions are not queued as media",split.media == [native] && split.captions == [plain])
        check("launch ignores argument-domain flags",AppDelegate.launchFiles(["NOIR","-AppleLanguages","(en)","-psn_0_1",native.path,directory.appendingPathComponent("missing.mp4").path]) == [URL(fileURLWithPath:native.path)])
        var tracks = PlaybackInfo(); tracks.audio = [TrackChoice(id:1,title:"English"),TrackChoice(id:2,title:"English")]; tracks.audioID = 2
        app.ui.sync(tracks,nil,backend:"",settings:app.preferences)
        check("duplicate track names stay selectable",app.ui.audio.numberOfItems == 2 && app.ui.audio.selectedTag() == 2)
        app.ui.sync(PlaybackInfo(),nil,backend:"",settings:app.preferences)
    }
    func nativeControls() {
        guard let app else { return }
        check("native dimensions",app.hub.info.size == CGSize(width:320,height:180))
        app.hub.pause(true); app.hub.seek(3); app.hub.setRate(1.25); app.hub.setAspect("4:3"); app.hub.rotate(); app.hub.loadSubtitle(directory.appendingPathComponent("plain.srt"))
        until("native paused seek",condition:{ !app.hub.info.playing && abs(app.hub.info.time-3)<0.25 }) {
            self.check("plain captions stay native",app.hub.backend == .native && app.ui.video.caption.stringValue == "NOIR native captions")
            app.hub.selectTrack(-1,subtitle:true)
            self.delay { self.check("captions off",app.ui.video.caption.isHidden); app.hub.selectTrack(1000,subtitle:true)
                self.delay {
                    app.hub.snapshot(self.directory.appendingPathComponent("native-snapshot.png")) { result in
                        switch result { case .success:
                            let image = NSImage(contentsOf:self.directory.appendingPathComponent("native-snapshot.png")); let rep = image?.representations.first
                            self.check("native rotated PNG",rep?.pixelsWide == 180 && rep?.pixelsHigh == 320)
                        case .failure(let error): self.check("native rotated PNG",false,error.localizedDescription) }
                        self.styledHandoff()
                    }
                    var busy = false
                    app.hub.snapshot(self.directory.appendingPathComponent("busy-snapshot.png")) { if case .failure = $0 { busy = true } }
                    self.check("concurrent snapshot reports busy",busy)
                }
            }
        }
    }
    func styledHandoff() {
        guard let app else { return }
        app.hub.loadSubtitle(directory.appendingPathComponent("styled.srt"))
        until("formatted caption handoff",condition:{ app.hub.backend == .compatibility && app.hub.info.ready && app.hub.info.size.width > 0 }) {
            self.delay(1.5) {
                self.check("handoff preserves paused position",!app.hub.info.playing && abs(app.hub.info.time-3)<1)
                app.hub.snapshot(self.directory.appendingPathComponent("vlc-snapshot.png")) { result in
                    self.check("VLC snapshot requested",(try? result.get()) != nil)
                    self.until("VLC PNG publication",condition:{ FileManager.default.fileExists(atPath:self.directory.appendingPathComponent("vlc-snapshot.png").path) }) {
                        let rep = NSImage(contentsOf:self.directory.appendingPathComponent("vlc-snapshot.png"))?.representations.first
                        self.check("compatibility rotation",rep?.pixelsWide == 180 && rep?.pixelsHigh == 320)
                        self.matroska()
                    }
                }
            }
        }
    }
    func matroska() {
        guard let app else { return }
        app.hub.rotation = 0; app.hub.setAspect("")
        app.add([MediaSource(directory.appendingPathComponent("fallback.mkv"))])
        until("unsupported container automatically falls back",condition:{ app.hub.backend == .compatibility && app.hub.info.ready && app.hub.info.size.width == 320 }) {
            app.hub.pause(true); app.hub.seek(5)
            self.until("VLC paused seek",condition:{ !app.hub.info.playing && abs(app.hub.info.time-5)<1 }) {
                app.perform("compact"); self.check("mini player",app.ui.compact && app.window.level == .floating); app.perform("compact")
                app.ui.search.stringValue = "native"; app.filter(); self.check("queue filter",app.filtered.count == 1); app.ui.search.stringValue = ""; app.filter()
                self.audio()
            }
        }
    }
    func audio() {
        guard let app else { return }; app.add([MediaSource(directory.appendingPathComponent("audio.wav"))])
        until("native stereo audio clock",condition:{ app.hub.backend == .native && app.hub.info.ready && app.hub.info.time>0.3 && app.hub.info.duration>4 }) {
            app.preferences.volume=42; app.hub.settings=app.preferences; app.hub.setVolume()
            self.check("native volume and mute",abs(app.hub.player.volume-0.42)<0.01 && app.hub.player.isMuted)
            if let address=ProcessInfo.processInfo.environment["NOIR_HTTP_TEST_URL"],let url=URL(string:address) {
                app.add([MediaSource(url)])
                self.until("native HTTP playback",condition:{ app.hub.backend == .native && app.hub.info.ready && app.hub.info.time>0.2 }) { self.bookmarks() }
            } else { self.bookmarks() }
        }
    }
    func bookmarks() {
        guard let app else { return }
        app.preferences.rememberPosition = true; app.preferences.autoPlayNext = false
        app.add([MediaSource(directory.appendingPathComponent("native.mp4"))])
        until("bookmark source ready",condition:{ app.hub.backend == .native && app.hub.info.ready }) {
            app.hub.pause(true); app.hub.seek(6)
            self.until("bookmark source paused at saved position",condition:{ !app.hub.info.playing && abs(app.hub.info.time-6)<0.15 }) {
                let key = app.active!.url.absoluteString
                app.perform("stop")
                self.check("stop retains playback bookmark",app.preferences.positions[key] == 6)
                app.bookmark(); app.preferences.save() // The quit path uses the same calls.
                self.check("quit after stop preserves persisted bookmark",Preferences.load().positions[key] == 6)
                app.perform("play")
                app.bookmark()
                self.check("opening source does not erase bookmark",app.preferences.positions[key] == 6)
                self.until("stopped source resumes from bookmark",condition:{ app.hub.info.ready && app.hub.info.time>=6 && app.hub.info.time<8 }) { self.compatibilityReplay() }
            }
        }
    }
    func compatibilityReplay() {
        guard let app else { return }
        let url = directory.appendingPathComponent("fallback.mkv")
        app.preferences.preferNative = false; app.preferences.autoPlayNext = false; app.preferences.repeatMode = 0
        app.preferences.positions[url.absoluteString] = 5
        app.add([MediaSource(url)])
        until("VLC bookmark startup",condition:{ app.hub.backend == .compatibility && app.hub.info.ready && app.hub.info.time>=5 }) {
            app.hub.seek(11.5); app.hub.pause(false)
            self.until("VLC reaches natural end",condition:{ app.hub.info.ended }) {
                app.perform("play")
                self.until("Play restarts ended VLC input at zero",condition:{ app.hub.info.playing && app.hub.info.time>0.1 && app.hub.info.time<2 }) {
                    app.hub.pause(true); app.hub.seek(11.3)
                    self.until("VLC repeat test positioned near end",condition:{ !app.hub.info.playing && app.hub.info.time>11 }) {
                        app.preferences.repeatMode = 2; app.hub.pause(false)
                        self.until("VLC Repeat One restarts at zero",condition:{ app.hub.info.playing && app.hub.info.time>0.1 && app.hub.info.time<2 }) { self.compatibilityAudioReplay() }
                    }
                }
            }
        }
    }
    func compatibilityAudioReplay() {
        guard let app else { return }
        app.preferences.repeatMode = 0; app.preferences.autoPlayNext = false
        app.add([MediaSource(directory.appendingPathComponent("audio.wav"))])
        until("VLC audio source ready",condition:{ app.hub.backend == .compatibility && app.hub.info.ready && app.hub.info.audioID>=0 }) {
            let audioID = app.hub.info.audioID
            // VLC does not move an audio-only clock while paused, so seek first and pause once there.
            app.hub.seek(2)
            self.until("VLC rotation test positioned",condition:{ app.hub.info.time >= 2 && app.hub.info.time < 3.5 }) {
                app.hub.pause(true); let position = app.hub.info.time
                // The second turn lands while VLC is still opening the first reopen.
                app.hub.rotate(); app.hub.rotate()
                self.until("rotating during VLC startup keeps position",condition:{ app.hub.info.ready && abs(app.hub.info.time-position)<0.6 }) {
                    self.delay(0.6) {
                        self.check("rotating during VLC startup keeps audio",app.hub.info.audioID == audioID,"\(app.hub.info.audioID)")
                        app.hub.rotation = 0; app.hub.pause(false)
                        self.compatibilityAudioOff(audioID)
                    }
                }
            }
        }
    }
    func compatibilityAudioOff(_ audioID: Int) {
        guard let app else { return }
        app.hub.selectTrack(-1,subtitle:false)
        self.until("VLC audio off selected",condition:{ app.hub.info.audioID == -1 }) {
            app.hub.seek(4.7)
            self.until("VLC audio-off source ends",condition:{ app.hub.info.ended }) {
                app.perform("play")
                self.until("VLC audio-off source replays",condition:{ app.hub.info.playing && app.hub.info.time>0.1 && app.hub.info.time<2 }) {
                    self.until("VLC replay retains audio off",timeout:3,condition:{ app.hub.info.audioID == -1 }) {
                        app.hub.selectTrack(audioID,subtitle:false)
                        self.until("VLC audio re-enabled",condition:{ app.hub.info.audioID == audioID }) {
                            app.hub.seek(4.7)
                            self.until("VLC audio-enabled source ends",condition:{ app.hub.info.ended }) {
                                app.perform("play")
                                self.until("VLC audio-enabled source replays",condition:{ app.hub.info.playing && app.hub.info.time>0.1 && app.hub.info.time<2 }) {
                                    self.until("VLC replay retains selected audio",timeout:3,condition:{ app.hub.info.audioID == audioID }) { self.singleItemShuffle() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func singleItemShuffle() {
        guard let app else { return }
        app.hub.stop(); app.queue = []; app.current = nil
        app.preferences.preferNative = true; app.preferences.rememberPosition = false
        app.preferences.shuffle = true; app.preferences.repeatMode = 1; app.preferences.autoPlayNext = true
        app.add([MediaSource(directory.appendingPathComponent("native.mp4"))])
        until("single-item shuffle source ready",condition:{ app.hub.backend == .native && app.hub.info.ready }) {
            app.hub.pause(true); app.hub.seek(11.3)
            self.until("shuffle repeat test positioned near end",condition:{ !app.hub.info.playing && app.hub.info.time>11 }) {
                app.hub.pause(false)
                self.until("single-item Shuffle Repeat All restarts",condition:{ app.hub.info.playing && app.hub.info.time>0.1 && app.hub.info.time<2 }) {
                    app.hub.pause(true); app.hub.seek(11.3)
                    self.until("shuffle off test positioned near end",condition:{ !app.hub.info.playing && app.hub.info.time>11 }) {
                        app.preferences.repeatMode = 0; app.hub.pause(false)
                        self.until("single-item Shuffle Repeat Off reaches end",condition:{ app.hub.info.ended }) {
                            self.delay { self.check("single-item Shuffle Repeat Off stays ended",app.hub.info.ended); self.seekAfterEnd() }
                        }
                    }
                }
            }
        }
    }
    func seekAfterEnd() {
        guard let app else { return }
        app.hub.seek(2)
        until("seeking after native end resumes playback",condition:{ app.hub.info.playing && app.hub.player.timeControlStatus == .playing && app.hub.info.time > 2.3 && app.hub.info.time < 6 }) { self.queueNavigation() }
    }
    func queueNavigation() {
        guard let app else { return }
        app.preferences.shuffle = false; app.preferences.autoPlayNext = false; app.preferences.repeatMode = 0
        let audio = directory.appendingPathComponent("audio.wav")
        app.add([MediaSource(audio)]) // queue: native, audio; audio is current
        app.ui.table.deselectAll(nil); app.perform("stop"); app.perform("play")
        check("Play after Stop resumes the current item",app.active?.url == audio && app.hub.source?.url == audio)
        app.add([MediaSource(directory.appendingPathComponent("fallback.mkv"))]); app.play(0) // native is current
        app.ui.table.selectRowIndexes([0],byExtendingSelection:false); app.removeSelected()
        app.perform("next")
        check("Next after removing the current item plays its successor",app.active?.url == audio,app.active?.title ?? "none")
        discFailures()
    }
    func discFailures() {
        guard let app else { return }
        // Keep a regular current item so these expected failures do not open
        // a modal disc-error sheet. The real PlaybackHub and VLC still run.
        app.preferences.repeatMode = 2; app.handledEnd = false
        let protected = directory.appendingPathComponent("protected-without-keys")
        do {
            try FileManager.default.createDirectory(at:protected.appendingPathComponent("BDMV"),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:protected.appendingPathComponent("AACS"),withIntermediateDirectories:true)
        } catch { check("protected disc fixture",false,error.localizedDescription); finish(); return }
        app.hub.open(MediaSource(protected,disc:true),settings:app.preferences)
        until("protected disc without keys fails before opening drive",condition:{ app.hub.info.failed && app.hub.info.failure.contains("AACS") }) {
            self.check("protection setup failure does not trigger Repeat One",!app.hub.info.ended && app.hub.info.status == "AACS setup required")
            app.handledEnd = false
            app.hub.open(MediaSource(self.directory.appendingPathComponent("disc-bluray"),disc:true),settings:app.preferences)
            self.until("VLC disc failure preserves decoder error",condition:{ app.hub.info.failed && !app.hub.info.failure.isEmpty }) {
                self.delay {
                    self.check("failed VLC disc stays failed instead of ended",app.hub.info.failed && !app.hub.info.ended && !app.hub.info.ready)
                    self.failureRecovery()
                }
            }
        }
    }
    func failureRecovery() {
        guard let app else { return }
        guard ProcessInfo.processInfo.environment["NOIR_DATA_DIR"] != nil else { check("failure recovery requires isolated settings",false); finish(); return }
        let key = AacsKeys.folder.appendingPathComponent("KEYDB.cfg"), original = try? Data(contentsOf:AacsKeys.folder.appendingPathComponent("KEYDB.cfg"))
        let savedUpdate = app.hub.update
        cleanup = { [weak app] in
            app?.hub.update = savedUpdate
            if let original { try? original.write(to:key,options:.atomic) } else { try? FileManager.default.removeItem(at:key) }
        }
        do { try FileManager.default.createDirectory(at:AacsKeys.folder,withIntermediateDirectories:true); if FileManager.default.fileExists(atPath:key.path) { try FileManager.default.removeItem(at:key) } }
        catch { check("isolated key setup",false,error.localizedDescription); finish(); return }
        // Suppress only expected error sheets while exercising the real Play action.
        app.hub.update = { [weak app] info in if !info.failed { app?.updated(info) } }
        app.preferences.repeatMode = 0; app.preferences.autoPlayNext = false; app.preferences.preferNative = false
        let source = MediaSource(directory.appendingPathComponent("protected-without-keys"),disc:true)
        app.queue = [source]; app.current = nil; app.filter(); app.play(0)
        until("retry fixture reports missing AACS keys",condition:{ app.hub.info.failed && app.hub.info.status == "AACS setup required" }) {
            do {
                try "| PK | 0x00000000000000000000000000000000\n".write(to:key,atomically:true,encoding:.utf8)
                try AacsKeys.validateInstalled()
            } catch { self.check("install synthetic retry credentials",false,error.localizedDescription); self.finish(); return }
            app.perform("play")
            self.check("Play reopens failed source after installing keys",!app.hub.info.failed && app.hub.info.status == "Opening…" && app.hub.source?.id == source.id)
            self.until("retry reaches decoder instead of stale setup failure",condition:{ app.hub.info.failed && app.hub.info.status != "AACS setup required" && !app.hub.info.failure.contains("key database is missing") }) {
                self.cleanup?(); self.cleanup = nil; self.delayedEOF()
            }
        }
    }
    func delayedEOF() {
        guard let app else { return }
        app.timer?.invalidate(); app.timer = nil
        app.preferences.preferNative = false; app.preferences.autoPlayNext = true; app.preferences.repeatMode = 0
        let short = directory.appendingPathComponent("short.wav"), next = directory.appendingPathComponent("audio.wav")
        let savedUpdate = app.hub.update
        var cleanEOF = false
        cleanup = { [weak app] in app?.hub.update = savedUpdate }
        app.hub.update = { [weak app] info in
            if app?.hub.source?.url == short && info.ended { cleanEOF = !info.failed }
            savedUpdate?(info)
        }
        app.queue = []; app.current = nil; app.add([MediaSource(short),MediaSource(next)])
        // Model a menu/window tracking operation which delays the first UI poll.
        delay(4) {
            app.hub.poll()
            self.until("successful EOF survives a delayed first playback poll",condition:{ cleanEOF }) {
                self.check("delayed EOF advances queue normally",app.hub.source?.url == next && !app.hub.info.failed)
                self.cleanup?(); self.cleanup = nil; self.finish()
            }
        }
    }
    func finish() {
        cleanup?(); cleanup = nil
        let passed = !checks.contains { $0["passed"] as? Bool == false }
        let report: [String:Any] = ["passed":passed,"architecture":"arm64","checks":checks,"physicalDiscTested":false]
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:directory.appendingPathComponent("smoke-report.json"),options:.atomic) }
        app?.hub.stop(); delay(0.5) { NSApp.terminate(nil) }
    }
}
