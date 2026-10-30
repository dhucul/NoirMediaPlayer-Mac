import AppKit
import AVFoundation

final class NativeCaptionObserver: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var text = ""
    func legibleOutput(_ output: AVPlayerItemLegibleOutput,didOutputAttributedStrings strings: [NSAttributedString],nativeSampleBuffers: [Any],forItemTime itemTime: CMTime) { text = strings.map(\.string).joined(separator:"\n") }
    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) { text = "" }
}

final class CompatibilityVideoView: NSView {
    /// VLC's embedded macOS renderer handles clicks, but its click handler
    /// does not update the pointer position. Refresh that before the click.
    @discardableResult func updatePointerPosition(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow,from:nil)
        guard bounds.contains(point),!isHiddenOrHasHiddenAncestor else { return false }
        for child in subviews.reversed() {
            if let target = child.hitTest(point) {
                target.mouseMoved(with:event); return true
            }
        }
        return false
    }
}

final class VideoSurface: NSView {
    let nativeLayer = AVPlayerLayer()
    let compatibilityView = CompatibilityVideoView()
    let caption = NSTextField(wrappingLabelWithString: "")
    let empty = Panel(.clear)
    var rotation = 0, aspect = ""
    var videoSize = CGSize(width:16,height:9)
    var maximumVideoScale: CGFloat?
    var fitsVideoToBounds = false
    var displayVideoSize: CGSize {
        let swapped = rotation % 180 != 0
        var size = swapped ? CGSize(width:videoSize.height,height:videoSize.width) : videoSize
        let values = aspect.split(separator:":").compactMap { Double($0) }
        if values.count == 2, values[0] > 0, values[1] > 0 { size.width = size.height*CGFloat(values[0]/values[1]) }
        return size
    }
    var drop: (([URL])->Void)?
    override init(frame: NSRect) {
        super.init(frame:frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10; layer?.masksToBounds = true
        layer?.addSublayer(nativeLayer); addSubview(compatibilityView); addSubview(empty); addSubview(caption)
        nativeLayer.videoGravity = .resizeAspect
        compatibilityView.isHidden = true
        caption.alignment = .center; caption.textColor = .white; caption.font = .systemFont(ofSize:22,weight:.semibold)
        caption.drawsBackground = true; caption.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        caption.isHidden = true; caption.maximumNumberOfLines = 6
        registerForDraggedTypes([.fileURL,.URL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); empty.frame = bounds
        let swapped = rotation % 180 != 0
        let reference = displayVideoSize
        guard reference.width > 0, reference.height > 0 else { return }
        let values = aspect.split(separator:":").compactMap { Double($0) }
        var scale = min(bounds.width/reference.width,bounds.height/reference.height)
        let capped = !fitsVideoToBounds && window?.styleMask.contains(.fullScreen) != true && maximumVideoScale != nil
        if capped, let maximumVideoScale { scale = min(scale,maximumVideoScale) }
        let size = CGSize(width:reference.width*scale,height:reference.height*scale)
        compatibilityView.frame = capped ? NSRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height) : bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        nativeLayer.setAffineTransform(.identity)
        nativeLayer.bounds = CGRect(origin:.zero,size:swapped ? CGSize(width:size.height,height:size.width) : size)
        nativeLayer.position = CGPoint(x:bounds.midX,y:bounds.midY)
        nativeLayer.videoGravity = values.count == 2 ? .resize : .resizeAspect
        nativeLayer.setAffineTransform(CGAffineTransform(rotationAngle:CGFloat(rotation)*CGFloat.pi/180))
        CATransaction.commit()
        let width = max(40,min(size.width-32,900))
        let height = min(160,caption.sizeThatFits(NSSize(width:width,height:160)).height+12)
        caption.frame = NSRect(x:bounds.midX-width/2,y:bounds.midY+size.height/2-height-18,width:width,height:height)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self], options:nil) as? [URL] ?? []
        if !urls.isEmpty { drop?(urls); return true }; return false
    }
}

// UI state is confined to the main thread; only VLCStorage is accessed on vlcQueue.
final class PlaybackHub: @unchecked Sendable {
    private final class VLCStorage: @unchecked Sendable { var value: OpaquePointer? }
    private let storage = VLCStorage()
    enum Backend: String { case none = "Ready", native = "macOS playback", compatibility = "Compatibility playback" }
    let surface: VideoSurface
    let player = AVPlayer()
    private let vlcQueue = DispatchQueue(label:"com.noirmediaplayer.compatibility",qos:.userInitiated)
    private var vlc: OpaquePointer?
    private var vlcPollPending = false
    private var generation = 0, opening = Date()
    private var asset: AVURLAsset?, item: AVPlayerItem?, metadataTask: Task<Void,Never>?
    private var audioGroup: AVMediaSelectionGroup?, subtitleGroup: AVMediaSelectionGroup?
    private var chapters: [Double] = []
    private var nativeLoaded = false, endedToken: NSObjectProtocol?
    private var resume: Double?, desiredPaused = false, nativeEnded = false, audioOff = false
    private var pendingAudio: Int?, pendingSubtitle: Int?
    private var pendingAudioName: String?, pendingSubtitleName: String?
    private var compatibilityAudioID: Int?, compatibilitySubtitleID: Int?
    private var imageGenerator: AVAssetImageGenerator?, snapshotCompletion: ((Result<Void,Error>)->Void)?
    private var terminated = false
    private var mouseMonitor: Any?
    private var nativeCaption: CaptionFile?
    private var embeddedCaptions: NativeCaptionObserver?
    private var externalSubtitles: [URL] = [], selectedExternal: URL?
    private(set) var backend = Backend.none
    private(set) var source: MediaSource?
    private(set) var info = PlaybackInfo()
    var settings = Preferences()
    var rotation = 0, aspect = ""
    var update: ((PlaybackInfo)->Void)?
    var notice: ((String)->Void)?
    init(_ surface: VideoSurface) {
        self.surface = surface; surface.nativeLayer.player = player
        // Set once here on the main thread: setenv on vlcQueue could race AppKit's getenv calls.
        setenv("VLC_PLUGIN_PATH",Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/VLC/plugins").path,1)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDown]) { [weak self] event in
            guard let self,self.backend == .compatibility,self.source?.disc == true,
                  event.window === self.surface.window else { return event }
            let forwarded = self.surface.compatibilityView.updatePointerPosition(event)
            // Let AppKit deliver the original click to VLC's mouseDown handler.
            // The moved event has already reached the correct embedded view.
            return forwarded && event.type == .mouseMoved ? nil : event
        }
    }
    func open(_ source: MediaSource, settings: Preferences, time: Double = 0, paused: Bool = false, forceCompatibility: Bool = false, preserveChoices: Bool = false) {
        generation += 1; let token = generation
        self.source = source; self.settings = settings; opening = Date(); resume = time > 0 ? time : nil
        desiredPaused = paused; nativeEnded = false; audioOff = false; nativeLoaded = false
        info = PlaybackInfo(); info.status = "Opening…"; update?(info)
        cancelSnapshot("Playback changed before the snapshot was saved.")
        metadataTask?.cancel(); player.pause(); player.replaceCurrentItem(with:nil); item = nil; asset = nil
        audioGroup = nil; subtitleGroup = nil; chapters = []; nativeCaption = nil; embeddedCaptions = nil
        if !preserveChoices { externalSubtitles = []; selectedExternal = nil; pendingAudio = nil; pendingSubtitle = nil; pendingAudioName = nil; pendingSubtitleName = nil; compatibilityAudioID = nil; compatibilitySubtitleID = nil }
        if let endedToken { NotificationCenter.default.removeObserver(endedToken); self.endedToken = nil }
        surface.caption.isHidden = true; surface.empty.isHidden = true
        surface.rotation = rotation; surface.aspect = aspect; surface.needsLayout = true
        let storage = self.storage
        vlcQueue.async { if let v = storage.value { nvlc_stop(v) } }
        let scheme = source.url.scheme?.lowercased() ?? ""
        let canTryNative = settings.preferNative && !source.disc && ["file","http","https"].contains(scheme) && !forceCompatibility
        if canTryNative {
            backend = .native; surface.nativeLayer.isHidden = false; surface.compatibilityView.isHidden = true
            let asset = AVURLAsset(url:source.url); self.asset = asset
            metadataTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let playable = try await asset.load(.isPlayable)
                    guard token == self.generation, !Task.isCancelled else { return }
                    guard playable else { self.fallback("This source needs compatibility playback"); return }
                    let item = AVPlayerItem(asset:asset); self.item = item
                    let output=AVPlayerItemLegibleOutput(); let observer=NativeCaptionObserver(); self.embeddedCaptions=observer
                    output.setDelegate(observer,queue:.main); item.add(output)
                    self.endedToken = NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) { [weak self] _ in self?.nativeEnded = true }
                    self.player.replaceCurrentItem(with:item); self.player.volume = Float(settings.volume/100); self.player.isMuted = settings.muted
                    if !self.desiredPaused { self.player.playImmediately(atRate:Float(settings.rate)) }
                    let audio = try? await asset.loadMediaSelectionGroup(for:.audible)
                    let subtitles = try? await asset.loadMediaSelectionGroup(for:.legible)
                    let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages:Locale.preferredLanguages)
                    guard token == self.generation, !Task.isCancelled else { return }
                    self.audioGroup = audio; self.subtitleGroup = subtitles; self.chapters = groups?.map { $0.timeRange.start.seconds } ?? []
                    if let url = self.selectedExternal { self.loadSubtitle(url) }
                    else if source.url.isFileURL {
                        for ext in ["srt","vtt"] {
                            let url = source.url.deletingPathExtension().appendingPathExtension(ext)
                            if FileManager.default.fileExists(atPath:url.path) { self.loadSubtitle(url); break }
                        }
                    }
                } catch { if token == self.generation, !Task.isCancelled { self.fallback(error.localizedDescription) } }
            }
        } else { startCompatibility(token:token) }
    }
    private func startCompatibility(token: Int) {
        backend = .compatibility; surface.nativeLayer.isHidden = true; surface.compatibilityView.isHidden = false
        let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libvlc.dylib").path
        let view = Unmanaged.passUnretained(surface.compatibilityView).toOpaque()
        let source = self.source!.playbackURL.absoluteString, hardware = settings.hardwareDecoding, rotation = self.rotation
        let discRoot = self.source!.playbackURL.scheme == "bluray" && self.source!.localDiscURL != nil ? URL(fileURLWithPath:self.source!.playbackURL.path) : nil
        let storage = self.storage
        let start = Int64((resume ?? 0)*1000), paused = desiredPaused, volume = Int32(settings.volume), muted = settings.muted
        vlcQueue.async { [weak self] in
            // Match Windows: reject missing protection prerequisites before
            // libbluray opens the physical drive or starts authentication.
            if let root = discRoot,FileManager.default.fileExists(atPath:root.appendingPathComponent("AACS").path) {
                do {
                    guard AacsRuntime.libraryPath != nil else { throw NoirError.message("AACS decoding library is unavailable. Rebuild with the bundled Apple Silicon AACS runtime or select a compatible library in Settings.") }
                    try AacsKeys.validateInstalled()
                } catch {
                    let failure = error.localizedDescription
                    DispatchQueue.main.async {
                        guard let self,!self.terminated,token == self.generation else { return }
                        self.info.failed = true; self.info.status = "AACS setup required"; self.info.failure = failure; self.update?(self.info)
                    }
                    return
                }
            }
            let v = storage.value ?? nvlc_create(library,view)
            storage.value = v
            let message = v == nil ? String(cString:nvlc_error()) : ""
            let result: Int32 = v.map { engine in
                nvlc_volume(engine,volume,paused || muted ? 1 : 0)
                return nvlc_open(engine,source,hardware ? 1 : 0,Int32(rotation),start)
            } ?? -1
            DispatchQueue.main.async {
                // After shutdown the engine is destroyed; do not restore a dangling pointer.
                guard let self, !self.terminated else { return }
                self.vlc = v
                guard token == self.generation else { return }
                if result != 0 { self.info.failed = true; self.info.status = "Unable to open source"; self.notice?(message.isEmpty ? "Compatibility playback could not open this source." : message); self.update?(self.info) }
            }
        }
    }
    private func fallback(_ reason: String) {
        guard backend == .native, let source else { return }
        let position = info.time > 0 ? info.time : resume ?? 0
        if info.ready, info.audioID == -1 { pendingAudio = -1 }
        else if info.ready { pendingAudioName = info.audio.first(where: { $0.id == info.audioID })?.title }
        if info.ready, selectedExternal == nil {
            if info.subtitleID == -1 { pendingSubtitle = -1 }
            else { pendingSubtitleName = info.subtitles.first(where: { $0.id == info.subtitleID })?.title }
        }
        notice?("Using compatibility playback")
        NSLog("NOIR native handoff: %@",reason)
        open(source,settings:settings,time:position,paused:desiredPaused,forceCompatibility:true,preserveChoices:true)
    }
    func poll() {
        guard backend != .none, !info.failed else { return }
        if backend == .native {
            if item?.status == .failed { fallback(item?.error?.localizedDescription ?? "Native decoder failed"); return }
            if !nativeLoaded && Date().timeIntervalSince(opening) > 15 { fallback("Native startup timed out"); return }
            guard let item else { return }
            if item.status == .readyToPlay {
                if !nativeLoaded {
                    nativeLoaded = true
                    if let time = resume { resume = nil; seek(time) }
                    if desiredPaused { player.pause() }
                }
                let time = player.currentTime().seconds, length = item.duration.seconds
                info.time = time.isFinite ? max(0,time) : 0; info.duration = length.isFinite ? max(0,length) : 0
                info.size = item.presentationSize; info.ready = true; info.playing = !desiredPaused && !nativeEnded
                info.ended = nativeEnded; info.status = nativeEnded ? "Ended" : desiredPaused ? "Paused" : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "Buffering…" : "Playing"
                info.audio = [TrackChoice(id:-1,title:"Audio off")] + (audioGroup?.options.enumerated().map { TrackChoice(id:$0.offset,title:$0.element.displayName) } ?? [TrackChoice(id:0,title:"Default audio")])
                info.subtitles = [TrackChoice(id:-1,title:"Subtitles off")] + (subtitleGroup?.options.enumerated().map { TrackChoice(id:$0.offset,title:$0.element.displayName) } ?? [])
                info.subtitles += externalSubtitles.enumerated().map { TrackChoice(id:1000+$0.offset,title:$0.element.lastPathComponent) }
                info.audioID = audioOff ? -1 : audioGroup.flatMap { g in g.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in:g) }) } ?? 0
                info.subtitleID = selectedExternal.flatMap { externalSubtitles.firstIndex(of:$0) }.map { 1000+$0 } ?? subtitleGroup.flatMap { g in g.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in:g) }) } ?? -1
                info.chapters = chapters.count; info.chapter = chapters.lastIndex(where: { $0 <= info.time }) ?? -1
                surface.videoSize = info.size; surface.needsLayout = true
                surface.caption.stringValue = nativeCaption?.text(at:info.time) ?? ""; surface.caption.isHidden = surface.caption.stringValue.isEmpty
                update?(info)
            }
        } else if !vlcPollPending, let vlc {
            vlcPollPending = true; let token = generation
            vlcQueue.async { [weak self] in
                let state = nvlc_state(vlc)
                let audio = Self.tracks(vlc,subtitle:false), subtitles = Self.tracks(vlc,subtitle:true)
                var message = [CChar](repeating:0,count:2048)
                nvlc_failure(vlc,&message,Int32(message.count))
                let failure = String(cString:message)
                DispatchQueue.main.async {
                    guard let self else { return }; self.vlcPollPending = false
                    guard token == self.generation, self.backend == .compatibility, !self.info.failed else { return }
                    self.info = PlaybackInfo(status:["Ready","Opening…","Buffering…","Playing","Paused","Stopped","Ended","Playback error"][min(7,max(0,Int(state.state)))], time:max(0,Double(state.time)/1000),duration:max(0,Double(state.length)/1000),playing:state.state == 3,ended:state.state == 6,failed:state.state == 7,ready:state.state == 3 || state.state == 4,size:CGSize(width:Int(state.width),height:Int(state.height)),audio:audio,subtitles:subtitles,audioID:Int(state.audio),subtitleID:Int(state.subtitle),chapter:Int(state.chapter),chapters:Int(state.chapters))
                    // VLC can report Ended after failing to open a protected disc.
                    // This must not enter Repeat One or erase the original failure.
                    if state.state == 7 || state.failed != 0 {
                        self.info.failed = true; self.info.ended = false; self.info.ready = false; self.info.playing = false; self.info.status = "Playback error"
                        self.info.failure = failure.isEmpty ? "No playable title could be opened from this source." : failure
                    }
                    if self.info.ready {
                        // VLC drops its input track inventory at EOF. Keep the
                        // last live selection for replay instead of treating that
                        // teardown's -1 track ID as an explicit Audio Off choice.
                        if !audio.isEmpty { self.compatibilityAudioID = self.info.audioID }
                        if !subtitles.isEmpty { self.compatibilitySubtitleID = self.info.subtitleID }
                        if !self.nativeLoaded {
                            self.nativeLoaded = true; self.resume = nil; self.setRate(self.settings.rate); self.setAspect(self.aspect)
                            // A paused handoff must first present a decoded frame. Pausing
                            // immediately at VLC's Playing event can leave an empty vout.
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in
                                guard let self, token == self.generation else { return }
                                if self.desiredPaused { self.pause(true) }; self.setVolume()
                            }
                            for url in self.externalSubtitles { self.command { _ = nvlc_subtitle($0,url.absoluteString) } }
                        }
                        func match(_ name: String?,in choices: [TrackChoice]) -> Int? {
                            guard let name,!name.isEmpty else { return nil }; return choices.first(where: { $0.id>=0 && ($0.title.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.title)) })?.id
                        }
                        if let id = self.pendingAudio ?? match(self.pendingAudioName,in:audio), id == -1 || audio.contains(where: { $0.id == id }) { self.selectTrack(id,subtitle:false); self.pendingAudio=nil; self.pendingAudioName=nil }
                        if let id = self.pendingSubtitle ?? match(self.pendingSubtitleName,in:subtitles), id == -1 || subtitles.contains(where: { $0.id == id }) { self.selectTrack(id,subtitle:true); self.pendingSubtitle=nil; self.pendingSubtitleName=nil }
                    }
                    if self.info.size.width > 0, self.info.size.height > 0 { self.surface.videoSize = self.info.size; self.surface.needsLayout = true }
                    self.update?(self.info)
                }
            }
        }
    }
    private static func tracks(_ vlc: OpaquePointer, subtitle: Bool) -> [TrackChoice] {
        var ids = [Int32](repeating:0,count:128), names = [CChar](repeating:0,count:128*512)
        let count = nvlc_tracks(vlc,subtitle ? 1 : 0,&ids,&names,128,512)
        return (0..<Int(count)).map { i in TrackChoice(id:Int(ids[i]),title:names.withUnsafeBufferPointer { String(cString:$0.baseAddress!.advanced(by:i*512)) }) }
    }
    private func command(_ action: @escaping (OpaquePointer)->Void) {
        let storage = self.storage; vlcQueue.async { if let v = storage.value { action(v) } }
    }
    func pause(_ value: Bool) {
        desiredPaused = value
        if backend == .native { if value { player.pause() } else { nativeEnded = false; player.playImmediately(atRate:Float(settings.rate)) } }
        else { command { nvlc_pause($0,value ? 1 : 0) } }
    }
    func togglePause() { pause(!desiredPaused) }
    func replay() {
        guard let source else { return }
        if backend == .compatibility {
            // An ended VLC input cannot resume through set_pause. Reopen with a
            // fresh zero start time, retaining the user's session selections.
            retainCompatibilityChoices()
            open(source,settings:settings,forceCompatibility:true,preserveChoices:true)
        } else if backend == .native { seek(0); pause(false) }
    }
    func seek(_ time: Double) {
        guard time.isFinite, backend != .none else { return }
        let target = max(0,info.duration > 0 ? min(time,info.duration) : time)
        guard backend == .native else { command { nvlc_seek($0,Int64(target*1000)) }; return }
        // Before the item is ready, a user seek replaces the pending resume position instead of being lost.
        guard nativeLoaded else { resume = target; return }
        // AVPlayer pauses itself at the end of an item. Resume after the seek lands unless the user paused.
        let restart = nativeEnded && !desiredPaused, token = generation
        nativeEnded = false
        player.seek(to:CMTime(seconds:target,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] finished in
            guard finished, restart else { return }
            DispatchQueue.main.async {
                guard let self, token == self.generation, !self.desiredPaused, !self.nativeEnded else { return }
                self.player.playImmediately(atRate:Float(self.settings.rate))
            }
        }
    }
    func setVolume() {
        player.volume = Float(settings.volume/100); player.isMuted = settings.muted || audioOff
        let volume = Int32(settings.volume), muted = settings.muted
        command { nvlc_volume($0,volume,muted ? 1 : 0) }
    }
    func setRate(_ rate: Double) { settings.rate = rate; if backend == .native && !desiredPaused { player.rate = Float(rate) }; command { nvlc_rate($0,Float(rate)) } }
    func setAspect(_ ratio: String) { aspect = ratio; surface.aspect = ratio; surface.needsLayout = true; command { nvlc_aspect($0,ratio.isEmpty ? nil : ratio) } }
    func rotate() {
        rotation = (rotation+90)%360; surface.rotation = rotation; surface.needsLayout = true
        guard backend == .compatibility, let source else { return }
        // Until VLC reports a live state, info holds reset defaults (-1 tracks, 0:00); keep the requested ones.
        retainCompatibilityChoices()
        open(source,settings:settings,time:info.ready ? info.time : resume ?? info.time,paused:desiredPaused,forceCompatibility:true,preserveChoices:true)
    }
    /// Carries VLC track choices into a reopen. VLC reports -1 while opening and after EOF, which is not an Off choice.
    private func retainCompatibilityChoices() {
        if let id = compatibilityAudioID ?? (info.ready ? info.audioID : nil) { pendingAudio = id }
        if let id = compatibilitySubtitleID ?? (info.ready ? info.subtitleID : nil) { pendingSubtitle = id }
    }
    func selectTrack(_ id: Int, subtitle: Bool) {
        if backend == .compatibility {
            if subtitle { compatibilitySubtitleID = id } else { compatibilityAudioID = id }
            command { nvlc_track($0,subtitle ? 1 : 0,Int32(id)) }; return
        }
        if subtitle {
            embeddedCaptions?.text = ""
            selectedExternal = id >= 1000 && id-1000 < externalSubtitles.count ? externalSubtitles[id-1000] : nil
            nativeCaption = selectedExternal.flatMap { try? CaptionFile($0) }
            if let group = subtitleGroup { item?.select(id >= 0 && id < group.options.count ? group.options[id] : nil,in:group) }
        } else {
            audioOff = id == -1
            if let group = audioGroup, id >= 0 && id < group.options.count { item?.select(group.options[id],in:group) }
            setVolume()
        }
    }
    func loadSubtitle(_ url: URL) {
        if !externalSubtitles.contains(url) { externalSubtitles.append(url) }; selectedExternal = url
        if backend == .native {
            do { nativeCaption = try CaptionFile(url); if let g = subtitleGroup { item?.select(nil,in:g) } }
            catch { fallback(error.localizedDescription) }
        } else if nativeLoaded { command { _ = nvlc_subtitle($0,url.absoluteString) } }
        // Otherwise VLC is still opening; its first ready poll adds every external subtitle once.
    }
    func chapter(_ offset: Int) {
        let target = max(0,min(info.chapters-1,info.chapter+offset)); guard info.chapters > 0 else { notice?("This source has no chapters"); return }
        if backend == .native { seek(chapters[target]) } else { command { nvlc_chapter($0,Int32(target)) } }
    }
    func navigate(_ direction: Int) { if backend == .compatibility { command { nvlc_navigate($0,UInt32(direction)) } } }
    func snapshot(_ url: URL, completion: @escaping (Result<Void,Error>)->Void) {
        guard info.size.width > 0 else { completion(.failure(NoirError.message("Open a video before taking a snapshot."))); return }
        if backend == .native, let asset {
            guard imageGenerator == nil else { completion(.failure(NoirError.message("A snapshot is already being saved."))); return }
            let generator = AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds:0.15,preferredTimescale:600); generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
            imageGenerator = generator; snapshotCompletion = completion; let token = generation, rotation = rotation
            let caption = nativeCaption?.text(at:info.time) ?? embeddedCaptions?.text ?? ""
            generator.generateCGImageAsynchronously(for:player.currentTime()) { [weak self] image,_,error in
                DispatchQueue.main.async {
                    guard let self, let completion = self.claimSnapshot(generator) else { return }
                    guard token == self.generation else { completion(.failure(NoirError.message("Playback changed before the snapshot was saved."))); return }
                    guard let image else { completion(.failure(error ?? NoirError.message("Snapshot unavailable."))); return }
                    do {
                        let bitmap = Self.compose(image,rotation:rotation,caption:caption)
                        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw NoirError.message("Cannot encode snapshot.") }
                        try data.write(to:url,options:.atomic); completion(.success(()))
                    } catch { completion(.failure(error)) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+10) { [weak self,weak generator] in
                guard let self, let generator, let completion = self.claimSnapshot(generator) else { return }
                generator.cancelAllCGImageGeneration(); completion(.failure(NoirError.message("Snapshot timed out.")))
            }
        } else {
            let rotation = self.rotation, storage = self.storage
            vlcQueue.async {
                let result = storage.value.map { nvlc_snapshot($0,url.path) } ?? -1
                DispatchQueue.main.async {
                    guard result == 0 else { completion(.failure(NoirError.message("Compatibility snapshot failed."))); return }
                    let deadline = Date().addingTimeInterval(3)
                    func published() {
                        if let image = NSImage(contentsOf:url), image.isValid {
                            // LibVLC 3 snapshots are taken before its display transform.
                            if rotation != 0, let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) {
                                do {
                                    guard let data = Self.compose(cg,rotation:rotation,caption:"").representation(using:.png,properties:[:]) else { throw NoirError.message("Cannot rotate snapshot.") }
                                    try data.write(to:url,options:.atomic)
                                } catch { completion(.failure(error)); return }
                            }
                            completion(.success(()))
                        }
                        else if Date() > deadline { completion(.failure(NoirError.message("No decoded frame is available for a snapshot yet."))) }
                        else { DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:published) }
                    }; published()
                }
            }
        }
    }
    /// Exactly one of the result, timeout or cancellation paths receives the snapshot completion.
    private func claimSnapshot(_ generator: AVAssetImageGenerator) -> ((Result<Void,Error>)->Void)? {
        guard imageGenerator === generator else { return nil }
        defer { imageGenerator = nil; snapshotCompletion = nil }
        return snapshotCompletion
    }
    private func cancelSnapshot(_ reason: String) {
        guard let generator = imageGenerator, let completion = claimSnapshot(generator) else { return }
        generator.cancelAllCGImageGeneration(); completion(.failure(NoirError.message(reason)))
    }
    static func compose(_ image: CGImage, rotation: Int, caption: String) -> NSBitmapImageRep {
        let swapped = rotation%180 != 0, w = swapped ? image.height : image.width, h = swapped ? image.width : image.height
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x:CGFloat(w)/2,y:CGFloat(h)/2); context.rotate(by:-CGFloat(rotation)*CGFloat.pi/180)
        context.draw(image,in:CGRect(x:-image.width/2,y:-image.height/2,width:image.width,height:image.height))
        context.rotate(by:CGFloat(rotation)*CGFloat.pi/180); context.translateBy(x:-CGFloat(w)/2,y:-CGFloat(h)/2)
        if !caption.isEmpty {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:CGFloat(h)*0.045,weight:.semibold),.foregroundColor:NSColor.white,.strokeColor:NSColor.black,.strokeWidth:-3,.paragraphStyle:style]
            (caption as NSString).draw(in:NSRect(x:20,y:CGFloat(h)*0.06,width:CGFloat(w)-40,height:CGFloat(h)*0.24),withAttributes:attrs)
        }
        NSGraphicsContext.restoreGraphicsState(); return bitmap
    }
    func stop(completion: (()->Void)? = nil) {
        generation += 1; metadataTask?.cancel(); cancelSnapshot("Playback stopped before the snapshot was saved.")
        let token = generation, storage = self.storage
        player.pause(); player.replaceCurrentItem(with:nil); item = nil; asset = nil; backend = .none; info = PlaybackInfo()
        vlcQueue.async { [weak self] in
            if let v = storage.value { nvlc_stop(v) }
            if let completion {
                DispatchQueue.main.async { guard self?.generation == token else { return }; completion() }
            }
        }
        surface.empty.isHidden = false; surface.caption.isHidden = true
        surface.nativeLayer.isHidden = true; surface.compatibilityView.isHidden = true; update?(info)
    }
    func shutdown(_ completion: @escaping ()->Void) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        stop(); terminated = true; let storage = self.storage; vlc = nil
        vlcQueue.async { if let v = storage.value { nvlc_destroy(v); storage.value = nil }; RunLoop.main.perform(inModes:[.default,.modalPanel,.eventTracking],block:completion) }
    }
}
