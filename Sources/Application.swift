import AppKit
import UniformTypeIdentifiers
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    let ui = PlayerInterface()
    lazy var hub = PlaybackHub(ui.video)
    var preferences = Preferences.load()
    var queue: [MediaSource] = [], filtered: [Int] = [], current: UUID?
    var history: [UUID] = [], shuffleBag: [UUID] = []
    var shuffleSeen = Set<UUID>()
    var timer: Timer?, keyMonitor: Any?, settingsPopover: NSPopover?
    var handledEnd = false, bookmarkTick = 0
    /// Queue slot of a removed current item, so Next/Previous continue from where it was.
    var vacatedIndex: Int?
    var savedFrame: NSRect?, savedMinimum: NSSize?
    var smokeRunner: SmokeRunner?
    var keyDownload: KeyDownload?
    var discEjector = DiscEjector()
    var active: MediaSource? { queue.first { $0.id == current } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named:.darkAqua)
        if !preferences.aacsLibrary.isEmpty,FileManager.default.fileExists(atPath:preferences.aacsLibrary) { setenv("LIBAACS_PATH",preferences.aacsLibrary,1) }
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:880),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "NOIR — Cinema without clutter"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.ink; window.contentView = ui; window.delegate = self; window.minSize = NSSize(width:1080,height:680); window.isReleasedWhenClosed = false
        if let screen = NSScreen.main { let frame = screen.visibleFrame; window.setContentSize(NSSize(width:min(1440,frame.width-60),height:min(880,frame.height-60))) }
        window.center(); window.level = preferences.alwaysOnTop ? .floating : .normal
        ui.action = { [weak self] in self?.perform($0) }; ui.video.drop = { [weak self] in self?.open($0) }
        ui.table.dataSource = self; ui.table.delegate = self; ui.table.target = self; ui.table.doubleAction = #selector(playSelection)
        ui.search.delegate = self
        for (control,selector) in [(ui.timeline,#selector(seekChanged)),(ui.volume,#selector(volumeChanged)),(ui.speed,#selector(speedChanged)),(ui.audio,#selector(audioChanged)),(ui.subtitles,#selector(subtitleChanged)),(ui.aspect,#selector(aspectChanged)),(ui.videoSize,#selector(sizeChanged))] { control.target = self; control.action = selector }
        ui.speed.selectItem(at:Preferences.rates.firstIndex(of:preferences.rate) ?? 3)
        hub.settings = preferences; hub.update = { [weak self] in self?.updated($0) }; hub.notice = { [weak self] in self?.showNotice($0) }
        buildMenu(); filter(); updated(PlaybackInfo())
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] e in self?.key(e) ?? e }
        timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in self?.hub.poll() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of:"--smoke-test"), args.count > index+1 { smokeRunner = SmokeRunner(app:self,directory:URL(fileURLWithPath:args[index+1])); smokeRunner?.start() }
        else { let urls = Self.launchFiles(args); if !urls.isEmpty { open(urls) } }
    }
    /// Existing paths from the command line. Argument-domain flags consume the next value (-AppleLanguages "(en)").
    static func launchFiles(_ arguments: [String]) -> [URL] {
        var urls: [URL] = [], skipValue = false
        for argument in arguments.dropFirst() {
            if argument.hasPrefix("-") { skipValue = !argument.hasPrefix("-psn_"); continue }
            if skipValue { skipValue = false; continue }
            if FileManager.default.fileExists(atPath:argument) { urls.append(URL(fileURLWithPath:argument)) }
        }
        return urls
    }
    func application(_ application: NSApplication, open urls: [URL]) { open(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bookmark(); preferences.save(); timer?.invalidate(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        hub.shutdown { NSApp.reply(toApplicationShouldTerminate:true) }; return .terminateLater
    }
    func windowDidResize(_ notification: Notification) { ui.needsLayout = true }
    func buildMenu() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ name: String) -> NSMenu { let item = NSMenuItem(title:name,action:nil,keyEquivalent:""); let sub = NSMenu(title:name); item.submenu = sub; main.addItem(item); return sub }
        func add(_ menu: NSMenu,_ title: String,_ action: String,_ key: String = "",_ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title:title,action:#selector(menuAction(_:)),keyEquivalent:key); item.representedObject = action; item.target = self; item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
        }
        let app = menu("NOIR"); add(app,"About NOIR Media Player","about"); app.addItem(.separator()); add(app,"Settings…","settings",","); app.addItem(.separator())
        let hide = NSMenuItem(title:"Hide NOIR",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h"); app.addItem(hide)
        app.addItem(.separator()); let quit = NSMenuItem(title:"Quit NOIR",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); app.addItem(quit)
        let file = menu("File"); add(file,"Open Media…","open","o"); add(file,"Open Folder…","folder","o",[.command,.shift]); add(file,"Play DVD / Disc…","disc","d"); add(file,"Eject Disc","eject","e"); add(file,"Open Network Stream…","network","l")
        let recent = NSMenuItem(title:"Open Recent",action:nil,keyEquivalent:""); let recentMenu = NSMenu(title:"Open Recent")
        for (i,source) in preferences.recents.enumerated() { add(recentMenu,source.title,"recent:\(i)") }; recent.submenu = recentMenu; file.addItem(recent)
        file.addItem(.separator()); add(file,"Save Playlist…","save","s",[.command,.shift]); add(file,"Load External Subtitle…","subtitle","v",[.command,.shift])
        let edit = menu("Edit"); for (title,sel,key) in [("Undo",Selector(("undo:")),"z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(NSMenuItem(title:title,action:sel,keyEquivalent:key)) }
        let playback = menu("Playback"); for (title,action) in [("Play / Pause","play"),("Stop","stop"),("Previous","previous"),("Next","next"),("Shuffle","shuffle"),("Cycle Repeat","repeat"),("Previous Chapter","prevChapter"),("Next Chapter","nextChapter"),("DVD Menu","discMenu")] { add(playback,title,action) }
        let view = menu("View"); add(view,"Toggle Fullscreen","fullscreen","f",[.command,.control]); add(view,"Mini Player","compact"); add(view,"Toggle Queue","sidebar"); add(view,"Toggle Inspector","inspector"); add(view,"Rotate 90°","rotate"); add(view,"Take Snapshot","snapshot"); add(view,"Open Snapshot Folder","snapshots")
        let help = menu("Help"); add(help,"Keyboard Shortcuts","shortcuts"); add(help,"Project on GitHub","github")
    }
    @objc func menuAction(_ sender: NSMenuItem) { if let action = sender.representedObject as? String { perform(action) } }
    func perform(_ action: String) {
        switch action {
        case "open": chooseFiles()
        case "folder": chooseFolder()
        case "disc": chooseDisc()
        case "eject": eject()
        case "network": network()
        case "play":
            if hub.backend == .none {
                // After Stop, resume the current item; the table selection may be stale.
                if let index = queue.firstIndex(where: { $0.id == current }) { play(index) }
                else if ui.table.selectedRow >= 0 { playSelection() } else if !queue.isEmpty { play(0) } else { chooseFiles() }
            }
            else if hub.info.ended { handledEnd = false; hub.replay() } else { hub.togglePause() }
        case "stop": bookmark(); hub.stop(); handledEnd = true
        case "next": next(1,user:true)
        case "previous": next(-1,user:true)
        case "shuffle": preferences.shuffle.toggle(); shuffleBag = []; shuffleSeen = Set(current.map { [$0] } ?? []); preferences.save(); updated(hub.info)
        case "repeat": preferences.repeatMode = (preferences.repeatMode+1)%3; preferences.save(); updated(hub.info)
        case "mute": preferences.muted.toggle(); hub.settings = preferences; hub.setVolume(); preferences.save(); updated(hub.info)
        case "subtitle","loadSubtitle": chooseSubtitle()
        case "snapshot": snapshot()
        case "rotate": hub.rotate(); showNotice("Rotation: \(hub.rotation)°")
        case "prevChapter": hub.chapter(-1)
        case "nextChapter": hub.chapter(1)
        case "discMenu": hub.navigate(5)
        case "compact","mini": toggleCompact()
        case "fullscreen": if ui.compact { toggleCompact() }; window.toggleFullScreen(nil)
        case "inspector","hideInspector": ui.showInspector.toggle(); ui.buttons["inspector"]?.title = ui.showInspector ? "Hide inspector" : "Show inspector"; ui.needsLayout = true
        case "sidebar": ui.showSidebar.toggle(); ui.needsLayout = true
        case "save": savePlaylist()
        case "remove": removeSelected()
        case "clear": bookmark(); hub.stop(); queue = []; current = nil; vacatedIndex = nil; history = []; shuffleBag = []; filter()
        case "settings": settings()
        case "snapshots": revealSnapshots()
        case "about": alert("NOIR Media Player for macOS","Apple Silicon · macOS 13 or later\nNative AVFoundation playback with VLC 3.0.23 compatibility fallback.\nPort of dhucul/NoirMediaPlayer 1.0.10.")
        case "shortcuts": alert("Keyboard shortcuts","Space: play/pause\n← / →: seek 10 seconds (Shift: 30)\n↑ / ↓: volume\nPage Up / Down: previous / next\nF / Escape: fullscreen\nP: mini player · M: mute · S: snapshot\nV: subtitle · R: repeat · H: shuffle\nI: inspector · B: queue\n⌥ arrows / Return: DVD menu navigation\n⌘O: files · ⇧⌘O: folder · ⌘D: disc\n⌘E: eject · ⌘L: network stream")
        case "github": NSWorkspace.shared.open(URL(string:"https://github.com/dhucul/NoirMediaPlayer-Mac")!)
        default: if action.hasPrefix("recent:"), let index = Int(action.dropFirst(7)), preferences.recents.indices.contains(index) { open([preferences.recents[index].url]) }
        }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.title = "Open media or playlist"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.beginSheetModal(for:window) { [weak self] result in if result == .OK { self?.open(panel.urls) } }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Open a media folder"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.beginSheetModal(for:window) { [weak self] result in if result == .OK { self?.open(panel.urls) } }
    }
    func chooseDisc() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil,options:[])?.filter(SourceReader.isDisc) ?? []
        if volumes.count == 1 { add([MediaSource(volumes[0],disc:true)]); return }
        let panel = NSOpenPanel(); panel.title = "Choose DVD, Blu-ray, VIDEO_TS, or BDMV folder"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = URL(fileURLWithPath:"/Volumes")
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            guard SourceReader.isDisc(url) else { self.alert("Disc folder not found","Choose a mounted DVD/Blu-ray or a folder containing VIDEO_TS or BDMV."); return }
            self.add([MediaSource(url,disc:true)])
        }
    }
    func eject() {
        guard let source = active,let device = discEjector.target(for:source) else { showNotice("Choose a mounted optical disc first"); return }
        bookmark(); let ejector = discEjector
        hub.stop { [weak self] in
            // Unmounting waits for the drive and can take seconds; keep the interface responsive.
            DispatchQueue.global(qos:.userInitiated).async {
                let result = Result { try ejector.eject(device) }
                DispatchQueue.main.async {
                    switch result { case .success: self?.showNotice("Disc ejected"); case .failure(let error): self?.alert("Cannot eject disc",error.localizedDescription) }
                }
            }
        }
    }
    func network() {
        let alert = NSAlert(); alert.messageText = "Open network stream"; alert.informativeText = "HTTP, HTTPS, RTSP, RTP, or UDP"; alert.addButton(withTitle:"Open"); alert.addButton(withTitle:"Cancel")
        let input = NSTextField(frame:NSRect(x:0,y:0,width:420,height:28)); input.placeholderString = "https://example.com/video.mp4"; alert.accessoryView = input; alert.window.initialFirstResponder = input
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let url = URL(string:input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), ["http","https","rtsp","rtp","udp"].contains(scheme), url.host != nil else { self?.alert("Invalid stream address","Enter a complete supported network URL."); return }
            self?.open([url])
        }
    }
    func open(_ urls: [URL]) {
        // Caption files are never queue entries; they attach to the playing (or newly opened) source.
        let (media,captions) = Self.splitCaptions(urls)
        if media.isEmpty && !captions.isEmpty {
            guard hub.backend != .none else { showNotice("Open media before loading subtitles"); return }
            captions.forEach(hub.loadSubtitle); return
        }
        showNotice("Reading sources…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try SourceReader.sources(media) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let sources): self.add(sources); if self.hub.backend != .none { captions.forEach(self.hub.loadSubtitle) }
                case .failure(let error): self.alert("Cannot open source",error.localizedDescription)
                }
            }
        }
    }
    static func splitCaptions(_ urls: [URL]) -> (media: [URL], captions: [URL]) {
        let caption = { (url: URL) in url.isFileURL && SourceReader.captions.contains(url.pathExtension.lowercased()) }
        return (urls.filter { !caption($0) },urls.filter(caption))
    }
    func add(_ sources: [MediaSource]) {
        guard !sources.isEmpty else { showNotice("No playable media found"); return }
        var first: Int?
        for source in sources {
            if let existing = queue.firstIndex(where: { $0.identity == source.identity }) { if first == nil { first = existing }; continue }
            if first == nil { first = queue.count }; queue.append(source)
        }
        shuffleBag = []; shuffleSeen = []; filter(); if let first { play(first) }
    }
    func play(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        bookmark(); let source = queue[index]; current = source.id; vacatedIndex = nil; handledEnd = false; history.append(source.id); if history.count > 500 { history.removeFirst() }
        if preferences.shuffle { shuffleSeen.insert(source.id) }
        preferences.recents.removeAll { $0.identity == source.identity }; preferences.recents.insert(source,at:0); preferences.recents = Array(preferences.recents.prefix(30)); preferences.save(); buildMenu()
        let resume = preferences.rememberPosition ? preferences.positions[source.url.absoluteString] ?? 0 : 0
        hub.open(source,settings:preferences,time:resume); filter()
    }
    func next(_ direction: Int,user: Bool) {
        guard !queue.isEmpty else { return }
        let position = queue.firstIndex(where: { $0.id == current })
        // Without a current item, sit just before the vacated slot (or the start), so Next plays
        // the item that moved into that slot rather than skipping it.
        let index = position ?? (vacatedIndex ?? 0)-1
        if direction < 0 {
            if hub.info.time > 3 { hub.seek(0); return }
            if preferences.shuffle, history.count > 1 { history.removeLast(); if let id = history.popLast(), let previous = queue.firstIndex(where:{ $0.id == id }) { play(previous) }; return }
            play(max(0,position == nil ? index : index-1)); return
        }
        if preferences.shuffle {
            shuffleBag.removeAll { id in !queue.contains(where: { $0.id == id }) || id == current }
            if shuffleBag.isEmpty {
                var candidates = queue.map(\.id).filter { !shuffleSeen.contains($0) && $0 != current }
                if candidates.isEmpty {
                    guard user || preferences.repeatMode == 1 else { return }
                    shuffleSeen = Set(current.map { [$0] } ?? []); candidates = queue.map(\.id).filter { $0 != current }
                    if queue.count == 1 { candidates = [queue[0].id] }
                }
                shuffleBag = candidates.shuffled()
            }
            if let id = shuffleBag.popLast(), let next = queue.firstIndex(where: { $0.id == id }) { play(next) }
            return
        }
        if index+1 < queue.count { play(index+1) }
        else if preferences.repeatMode == 1 || user { play(0) }
    }
    func bookmark() {
        guard hub.backend != .none,hub.info.ready,let source = active,source.id == hub.source?.id else { return }
        preferences.bookmark(source,time:hub.info.time,duration:hub.info.duration)
    }
    func updated(_ info: PlaybackInfo) {
        ui.sync(info,active,backend:hub.backend.rawValue,settings:preferences)
        if info.duration > 0, let index = queue.firstIndex(where: { $0.id == current }), abs(queue[index].duration-info.duration) > 1 { queue[index].duration = info.duration; ui.table.reloadData() }
        bookmarkTick += 1; if bookmarkTick%40 == 0 { bookmark(); preferences.save() }
        // Playback resumed after an end (for example a seek back), so the next end is handled again.
        if info.playing && !info.ended { handledEnd = false }
        if info.ended && !handledEnd {
            handledEnd = true
            if let source = active { preferences.positions.removeValue(forKey:source.url.absoluteString) }
            if preferences.repeatMode == 2 { handledEnd = false; hub.replay() }
            else if preferences.autoPlayNext { next(1,user:false) }
        }
        if info.failed && !handledEnd { handledEnd = true; showNotice("Cannot play this source") }
    }
    func filter() {
        let query = ui.search.stringValue
        filtered = queue.indices.filter { query.isEmpty || queue[$0].title.localizedCaseInsensitiveContains(query) || queue[$0].detail.localizedCaseInsensitiveContains(query) }
        ui.queueCount.stringValue = "\(queue.count) ITEMS"; ui.emptyQueue.isHidden = !queue.isEmpty; ui.table.reloadData()
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell"); let cell = tableView.makeView(withIdentifier:id,owner:self) as? QueueCell ?? QueueCell(frame:.zero); cell.identifier = id
        let source = queue[filtered[row]]; cell.configure(source,playing:source.id == current); return cell
    }
    @objc func playSelection() { let row = ui.table.selectedRow; if filtered.indices.contains(row) { play(filtered[row]) } }
    func removeSelected() {
        let row = ui.table.selectedRow; guard filtered.indices.contains(row) else { return }; let index = filtered[row]
        if queue[index].id == current { bookmark(); hub.stop(); current = nil; vacatedIndex = index }
        else if let vacated = vacatedIndex, index < vacated { vacatedIndex = vacated-1 }
        queue.remove(at:index); filter()
    }
    @objc func seekChanged() { hub.seek(ui.timeline.doubleValue/1000*hub.info.duration) }
    @objc func volumeChanged() { preferences.volume = ui.volume.doubleValue; hub.settings = preferences; hub.setVolume(); preferences.save() }
    @objc func speedChanged() { preferences.rate = Preferences.rates[max(0,ui.speed.indexOfSelectedItem)]; hub.setRate(preferences.rate); preferences.save() }
    @objc func audioChanged() { hub.selectTrack(ui.audio.selectedTag(),subtitle:false) }
    @objc func subtitleChanged() { hub.selectTrack(ui.subtitles.selectedTag(),subtitle:true) }
    @objc func aspectChanged() { hub.setAspect(ui.aspect.indexOfSelectedItem == 0 ? "" : ui.aspect.titleOfSelectedItem ?? "") }
    @objc func sizeChanged() {
        guard hub.info.size.width > 0, !window.styleMask.contains(.fullScreen) else { return }
        let scale = [0.5,1.0,2.0][max(0,ui.videoSize.indexOfSelectedItem)], size = hub.info.size
        let screen = window.screen?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900), extra: CGFloat = (ui.showSidebar ? 246 : 0)+(ui.showInspector ? 280 : 0)+24
        window.setContentSize(NSSize(width:max(window.minSize.width,min(screen.width-40,size.width*scale+extra)),height:max(window.minSize.height,min(screen.height-40,size.height*scale+240))))
    }
    func chooseSubtitle() {
        guard hub.backend != .none else { showNotice("Open media before loading subtitles"); return }
        let panel = NSOpenPanel(); panel.title = "Load external subtitle"; panel.allowedContentTypes = SourceReader.captions.compactMap { UTType(filenameExtension:$0) }
        panel.beginSheetModal(for:window) { [weak self] response in if response == .OK, let url = panel.url { self?.hub.loadSubtitle(url) } }
    }
    func savePlaylist() {
        let panel = NSSavePanel(); panel.title = "Save queue as playlist"; panel.nameFieldStringValue = "Noir Playlist.m3u8"; panel.allowedContentTypes = [UTType(filenameExtension:"m3u8") ?? .plainText]
        panel.beginSheetModal(for:window) { [weak self] response in guard let self, response == .OK, let url = panel.url else { return }; do { try SourceReader.playlistText(self.queue).write(to:url,atomically:true,encoding:.utf8); self.showNotice("Playlist saved") } catch { self.alert("Cannot save playlist",error.localizedDescription) } }
    }
    func snapshot() {
        do {
            let folder = preferences.snapshots; try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let name = "NOIR-"+ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")+"-"+String(UUID().uuidString.prefix(6))+".png"
            hub.snapshot(folder.appendingPathComponent(name)) { [weak self] result in switch result { case .success: self?.showNotice("Snapshot saved to Noir Snapshots"); case .failure(let error): self?.showNotice(error.localizedDescription) } }
        } catch { alert("Cannot save snapshot",error.localizedDescription) }
    }
    func revealSnapshots() { do { try FileManager.default.createDirectory(at:preferences.snapshots,withIntermediateDirectories:true); NSWorkspace.shared.open(preferences.snapshots) } catch { alert("Cannot open folder",error.localizedDescription) } }
    func toggleCompact() {
        // A fullscreen window cannot also be the floating mini player.
        if !ui.compact && window.styleMask.contains(.fullScreen) { showNotice("Exit fullscreen to use the mini player"); return }
        ui.compact.toggle()
        if ui.compact { savedFrame = window.frame; savedMinimum = window.minSize; window.minSize = NSSize(width:480,height:320); window.setContentSize(NSSize(width:640,height:420)); window.level = .floating }
        else { window.minSize = savedMinimum ?? NSSize(width:1080,height:680); if let savedFrame { window.setFrame(savedFrame,display:true) }; window.level = preferences.alwaysOnTop ? .floating : .normal }
        ui.needsLayout = true
    }
    func key(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window.attachedSheet == nil else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { return event }
        if window.firstResponder is NSTextView { return event }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods.contains(.control) { if let action = ["o":mods.contains(.shift) ? "folder" : "open","d":"disc","e":"eject","l":"network"][chars] { perform(action); return nil }; return event }
        if mods.contains(.option) {
            let directions: [UInt16:Int] = [126:1,125:2,123:3,124:4,36:0]
            if let direction = directions[event.keyCode] { hub.navigate(direction); return nil }
        }
        switch event.keyCode {
        case 123,124: hub.seek(hub.info.time+(event.keyCode == 123 ? -1 : 1)*(mods.contains(.shift) ? 30 : 10)); return nil
        case 125,126: preferences.volume = min(100,max(0,preferences.volume+(event.keyCode == 126 ? 5 : -5))); hub.settings = preferences; hub.setVolume(); preferences.save(); return nil
        case 116: perform("previous"); return nil
        case 121: perform("next"); return nil
        case 53: if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else if ui.compact { toggleCompact() }; return nil
        case 36: if active?.disc == true { hub.navigate(0) } else { playSelection() }; return nil
        case 51,117: if window.firstResponder === ui.table { removeSelected(); return nil }
        default: break
        }
        if let action = [" ":"play","f":"fullscreen","p":"compact","m":"mute","s":"snapshot","v":"subtitle","r":"repeat","h":"shuffle","i":"inspector","b":"sidebar"][chars] { perform(action); return nil }
        return event
    }
    var noticeGeneration = 0
    func showNotice(_ text: String) { noticeGeneration += 1; let token = noticeGeneration; ui.notice.stringValue = text; ui.notice.isHidden = false; DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in if self?.noticeGeneration == token { self?.ui.notice.isHidden = true } } }
    func alert(_ title: String,_ message: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.beginSheetModal(for:window) }
    func settings() {
        let controller = NSViewController(); let panel = Panel(); panel.frame = NSRect(x:0,y:0,width:354,height:504); controller.view = panel
        let heading = label("QUICK SETTINGS",13,color:Palette.bright,weight:.bold); heading.frame = NSRect(x:18,y:18,width:310,height:22); panel.addSubview(heading)
        let titles = ["Remember playback position","Automatically play the next item","Prefer macOS playback","Hardware decoding in compatibility playback","Keep player above other windows"]
        let states = [preferences.rememberPosition,preferences.autoPlayNext,preferences.preferNative,preferences.hardwareDecoding,preferences.alwaysOnTop]
        for (i,text) in titles.enumerated() { let check = NSButton(checkboxWithTitle:text,target:self,action:#selector(settingChanged(_:))); check.tag = i; check.font = .systemFont(ofSize:11); check.state = states[i] ? .on : .off; check.frame = NSRect(x:18,y:56+CGFloat(i)*32,width:320,height:26); panel.addSubview(check) }
        let note = label("Playback preferences apply when a source opens.\nmacOS manages decoding for native playback.",10,color:Palette.muted); note.maximumNumberOfLines = 2; note.frame = NSRect(x:18,y:224,width:316,height:36); panel.addSubview(note)
        let aacs = section("BLU-RAY AACS"); aacs.frame = NSRect(x:18,y:274,width:316,height:16); panel.addSubview(aacs)
        let keyExists=FileManager.default.fileExists(atPath:AacsKeys.folder.appendingPathComponent("KEYDB.cfg").path)
        let aacsStatus=label((preferences.aacsLibrary.isEmpty ? "AACS library not configured" : "External AACS library configured") + (keyExists ? "\nKey database found; disc keys not yet verified" : "\nNo key database found"),10,color:Palette.muted); aacsStatus.maximumNumberOfLines=2; aacsStatus.frame=NSRect(x:18,y:296,width:316,height:34); panel.addSubview(aacsStatus)
        let library=ActionButton("Choose library…") { [weak self] in self?.chooseAacs() }; library.frame=NSRect(x:18,y:342,width:152,height:30); panel.addSubview(library)
        let keys = ActionButton("Open key folder",symbol:"folder") { [weak self] in self?.openKeys() }; keys.frame = NSRect(x:182,y:342,width:152,height:30); panel.addSubview(keys)
        let download=ActionButton("Download AACS keys",symbol:"arrow.down.circle") { [weak self] in self?.downloadKeys() }; download.frame=NSRect(x:18,y:384,width:316,height:30); download.isEnabled=keyDownload==nil; panel.addSubview(download)
        let snapshots = ActionButton("Open snapshot folder",symbol:"camera") { [weak self] in self?.revealSnapshots() }; snapshots.frame = NSRect(x:18,y:426,width:316,height:30); panel.addSubview(snapshots)
        let foot = label("macOS playback · VLC compatibility fallback · Local settings",9,color:Palette.muted); foot.frame = NSRect(x:18,y:478,width:320,height:16); panel.addSubview(foot)
        let popover = NSPopover(); popover.contentViewController = controller; popover.behavior = .transient; popover.contentSize = panel.frame.size; settingsPopover = popover; popover.show(relativeTo:ui.buttons["settings"]!.bounds,of:ui.buttons["settings"]!,preferredEdge:.minY)
    }
    @objc func settingChanged(_ sender: NSButton) {
        let value = sender.state == .on
        switch sender.tag { case 0: preferences.rememberPosition = value; case 1: preferences.autoPlayNext = value; case 2: preferences.preferNative = value; case 3: preferences.hardwareDecoding = value; case 4: preferences.alwaysOnTop = value; window.level = value || ui.compact ? .floating : .normal; default: break }
        preferences.save()
    }
    func openKeys() {
        // libaacs' standard macOS key location. No keys are downloaded implicitly.
        let folder = AacsKeys.folder
        do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); NSWorkspace.shared.open(folder) } catch { alert("Cannot open key folder",error.localizedDescription) }
    }
    func chooseAacs() {
        settingsPopover?.close(); let panel=NSOpenPanel(); panel.title="Choose an Apple Silicon libaacs.dylib"; panel.canChooseDirectories=false
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self,result == .OK,let url=panel.url else { return }
            do {
                let size=try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? Int ?? 0
                guard size>0,size<=64*1024*1024,url.pathExtension=="dylib" else { throw NoirError.message("Choose an arm64 libaacs dynamic library.") }
                let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/lipo"); process.arguments=["-verify_arch","arm64",url.path]; process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice; try process.run(); process.waitUntilExit()
                guard process.terminationStatus==0 else { throw NoirError.message("The library does not contain Apple Silicon code.") }
                guard let handle=dlopen(url.path,RTLD_LAZY | RTLD_LOCAL) else { throw NoirError.message("The library or one of its dependencies could not be loaded.") }
                let valid=dlsym(handle,"aacs_open") != nil && dlsym(handle,"aacs_close") != nil; dlclose(handle)
                guard valid else { throw NoirError.message("This library does not provide the AACS interface.") }
                self.preferences.aacsLibrary=url.path; self.preferences.save(); self.showNotice("AACS library selected. Restart NOIR to apply it.")
            } catch { self.alert("Cannot use AACS library",error.localizedDescription) }
        }
    }
    func downloadKeys() {
        guard keyDownload==nil else { return }; settingsPopover?.close(); showNotice("Downloading AACS key database…")
        let download=KeyDownload { [weak self] result in
            guard let self else { return }; self.keyDownload=nil
            DispatchQueue.global(qos:.utility).async {
                let installed=Result { ()->Void in
                    let data=try AacsKeys.database(result.get()); try FileManager.default.createDirectory(at:AacsKeys.folder,withIntermediateDirectories:true)
                    try data.write(to:AacsKeys.folder.appendingPathComponent("KEYDB.cfg"),options:.atomic)
                }
                DispatchQueue.main.async { switch installed { case .success: self.showNotice("AACS key database installed"); case .failure(let error): self.alert("Cannot download AACS keys",error.localizedDescription) } }
            }
        }; keyDownload=download; download.start()
    }
}
