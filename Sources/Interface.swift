import AppKit

enum Palette {
    static let ink = NSColor(hex:0x050608), panel = NSColor(hex:0x0C0E12), raised = NSColor(hex:0x13161C)
    static let line = NSColor(hex:0x242932), accent = NSColor(hex:0x76A86E), text = NSColor(hex:0xC7CBD1), bright = NSColor(hex:0xDDE0E3), muted = NSColor(hex:0x858D98)
}
extension NSColor {
    convenience init(hex: Int) { self.init(srgbRed:CGFloat(hex>>16 & 255)/255,green:CGFloat(hex>>8 & 255)/255,blue:CGFloat(hex & 255)/255,alpha:1) }
}
class Panel: NSView {
    override var isFlipped: Bool { true }
    init(_ color: NSColor = Palette.panel) { super.init(frame:.zero); wantsLayer = true; layer?.backgroundColor = color.cgColor }
    required init?(coder: NSCoder) { fatalError() }
}
final class ActionButton: NSButton {
    var run: (()->Void)?
    var accent = false, selected = false, flat = false, hovered = false
    init(_ title: String = "", symbol: String? = nil, help: String = "", action: @escaping ()->Void) {
        super.init(frame:.zero); self.title = title; self.run = action; self.toolTip = help.isEmpty ? title : help
        isBordered = false; bezelStyle = .regularSquare; font = .systemFont(ofSize:11,weight:.medium)
        target = self; self.action = #selector(invoke); imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if let symbol { image = NSImage(systemSymbolName:symbol,accessibilityDescription:help.isEmpty ? title : help) }
        setAccessibilityLabel(help.isEmpty ? title : help)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func invoke() { run?() }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseEnteredAndExited,.inVisibleRect],owner:self)); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let color = accent ? Palette.accent : selected ? NSColor(hex:0x202A20) : hovered ? NSColor(hex:0x1B1F27) : flat ? .clear : Palette.raised
        color.setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:7,yRadius:7).fill()
        if !flat && !accent { Palette.line.setStroke(); NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:7,yRadius:7).stroke() }
        contentTintColor = accent ? NSColor(hex:0x10180D) : selected ? Palette.accent : isEnabled ? Palette.text : Palette.muted.withAlphaComponent(0.4)
        attributedTitle = NSAttributedString(string:title,attributes:[.font:font!,.foregroundColor:contentTintColor!])
        super.draw(dirtyRect)
    }
}
func label(_ text: String, _ size: CGFloat = 11, color: NSColor = Palette.text, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString:text); field.font = .systemFont(ofSize:size,weight:weight); field.textColor = color
    field.lineBreakMode = .byTruncatingTail; return field
}
func section(_ text: String) -> NSTextField { label(text,9,color:Palette.muted,weight:.bold) }
final class DiscArtwork: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex:0x050608).setFill(); NSBezierPath(roundedRect:bounds,xRadius:10,yRadius:10).fill()
        Palette.line.setStroke(); NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10).stroke()
        let outer = NSRect(x:bounds.midX-36,y:bounds.midY-36,width:72,height:72)
        let circle = NSBezierPath(ovalIn:outer); circle.lineWidth = 8; Palette.line.setStroke(); circle.stroke()
        Palette.accent.setFill(); NSBezierPath(ovalIn:NSRect(x:bounds.midX-6,y:bounds.midY-6,width:12,height:12)).fill()
    }
}
final class QueueCell: NSTableCellView {
    let name = label("",12,color:Palette.bright,weight:.semibold), detail = label("",9,color:Palette.muted), kind = label("",8,color:Palette.muted), time = label("",9,color:Palette.muted)
    let marker = label("▶",12,color:Palette.muted)
    override init(frame: NSRect) { super.init(frame:frame); for v in [name,detail,kind,time,marker] { addSubview(v) }; kind.alignment = .right; time.alignment = .right }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); marker.frame = NSRect(x:8,y:17,width:22,height:20); name.frame = NSRect(x:36,y:8,width:max(20,bounds.width-94),height:18)
        detail.frame = NSRect(x:36,y:29,width:max(20,bounds.width-94),height:14); kind.frame = NSRect(x:bounds.width-53,y:10,width:45,height:12); time.frame = NSRect(x:bounds.width-53,y:28,width:45,height:14)
    }
    func configure(_ source: MediaSource, playing: Bool) { name.stringValue = source.title; detail.stringValue = source.detail; kind.stringValue = source.kind; time.stringValue = source.duration > 0 ? clockText(source.duration) : ""; name.textColor = playing ? Palette.accent : Palette.bright; marker.textColor = playing ? Palette.accent : Palette.muted; marker.stringValue = playing ? "▰" : "▷" }
}

final class PlayerInterface: Panel {
    var action: ((String)->Void)?
    let header = Panel(NSColor(hex:0x08090C)), sidebar = Panel(), inspector = Panel(), footer = Panel(NSColor(hex:0x08090C)), center = Panel(NSColor(hex:0x020304))
    let video = VideoSurface(), controls = Panel(Palette.ink)
    let title = label("Ready for a film",11,color:Palette.muted), status = label("●  Ready",9,color:Palette.muted)
    let shortcut = label("SPACE  play/pause    F  fullscreen    ← →  seek",9,color:Palette.muted)
    let brand = label("N O I R",13,color:Palette.bright,weight:.bold), badge = label("PLAYER",8,color:Palette.muted,weight:.bold)
    let logo = label("N",14,color:NSColor(hex:0x10180D),weight:.black)
    let sourceLabel = section("SOURCES"), queueLabel = section("QUEUE"), queueCount = section("0 ITEMS")
    let search = NSSearchField(), table = NSTableView(), queueScroll = NSScrollView()
    let emptyQueue = label("Your queue is empty\nDrop files anywhere",11,color:Palette.muted)
    let now = section("NOW PLAYING"), artwork = DiscArtwork(), nowTitle = label("Nothing queued",19,color:Palette.bright,weight:.semibold), nowSource = label("Choose a source to begin",11,color:Palette.muted)
    let format = label("READY",9,color:Palette.accent,weight:.bold), resolution = label("—",9,color:Palette.muted), rateBadge = label("1.00×",9,color:Palette.muted), backend = label("macOS playback · VLC fallback",9,color:Palette.muted)
    let audio = NSPopUpButton(), subtitles = NSPopUpButton(), aspect = NSPopUpButton(), videoSize = NSPopUpButton(), speed = NSPopUpButton()
    let timeline = NSSlider(value:0,minValue:0,maxValue:1000,target:nil,action:nil), volume = NSSlider(value:82,minValue:0,maxValue:100,target:nil,action:nil)
    let elapsed = label("0:00",10,color:Palette.muted), remaining = label("−0:00",10,color:Palette.muted)
    let inspectorScroll = NSScrollView(), inspectorBody = Panel()
    let notice = label("",12,color:Palette.bright,weight:.medium)
    var buttons: [String:ActionButton] = [:]
    var showSidebar = true, showInspector = true, compact = false
    private var sourceButtons: [ActionButton] = [], tools: [ActionButton] = [], primary: [ActionButton] = []
    private var inspectorLabels: [NSView] = []
    override init(_ color: NSColor = Palette.ink) {
        super.init(color)
        registerForDraggedTypes([.fileURL,.URL])
        for v in [header,sidebar,center,inspector,footer] { addSubview(v) }
        for v in [logo,brand,badge,title] { header.addSubview(v) }
        logo.alignment = .center; logo.wantsLayer = true; logo.layer?.backgroundColor = Palette.accent.cgColor; logo.layer?.cornerRadius = 7
        _ = button("open","Open",symbol:"folder",parent:header); _ = button("inspector","Hide inspector",symbol:"sidebar.right",parent:header); _ = button("settings","",symbol:"gearshape",parent:header)
        for v in [sourceLabel,search,queueLabel,queueCount,queueScroll,emptyQueue] { sidebar.addSubview(v) }
        search.placeholderString = "Filter queue"; search.font = .systemFont(ofSize:11); search.setAccessibilityLabel("Filter queue")
        sourceButtons = [("open","Open media","doc.on.doc"),("folder","Open folder","folder"),("disc","Play DVD / disc","opticaldisc"),("eject","Eject disc","eject"),("network","Open network stream","network")].map { key,title,symbol in
            let b = ActionButton(title,symbol:symbol) { [weak self] in self?.action?(key) }; b.flat = true; b.alignment = .left; sidebar.addSubview(b); return b
        }
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("queue")); column.width = 220; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 54; table.intercellSpacing = .zero; table.backgroundColor = Palette.panel; table.selectionHighlightStyle = .regular; table.usesAlternatingRowBackgroundColors = false
        table.setAccessibilityLabel("Play queue"); queueScroll.documentView = table; queueScroll.hasVerticalScroller = true; queueScroll.drawsBackground = false
        emptyQueue.alignment = .center; emptyQueue.maximumNumberOfLines = 2
        _ = button("save","Save",symbol:"square.and.arrow.down",parent:sidebar); _ = button("remove","",symbol:"trash",parent:sidebar); _ = button("clear","",symbol:"text.badge.xmark",parent:sidebar)
        center.addSubview(video); center.addSubview(controls); center.addSubview(notice); notice.isHidden = true; notice.alignment = .center; notice.wantsLayer = true; notice.layer?.backgroundColor = Palette.raised.withAlphaComponent(0.95).cgColor; notice.layer?.cornerRadius = 7
        let emptyIcon = ActionButton("",symbol:"play.circle",help:"Open media") { [weak self] in self?.action?("open") }; emptyIcon.image = NSImage(systemSymbolName:"play.circle",accessibilityDescription:"Open media")?.withSymbolConfiguration(.init(pointSize:34,weight:.light)); emptyIcon.flat = true; video.empty.addSubview(emptyIcon); buttons["emptyOpen"] = emptyIcon
        let headline = label("MAKE THE ROOM GO QUIET",16,color:Palette.bright,weight:.bold), subhead = label("Open a film, drop a folder, or insert a disc",12,color:Palette.muted)
        headline.alignment = .center; subhead.alignment = .center; video.empty.addSubview(headline); video.empty.addSubview(subhead); headline.identifier = .init("headline"); subhead.identifier = .init("subhead")
        for v in [elapsed,timeline,remaining,speed,volume] { controls.addSubview(v) }; remaining.alignment = .right
        tools = [("shuffle","shuffle","Shuffle (H)"),("repeat","repeat","Repeat (R)"),("subtitle","captions.bubble","Load subtitle (V)"),("snapshot","camera","Snapshot (S)")].map { key,symbol,help in let b = button(key,"",symbol:symbol,help:help,parent:controls); b.flat = true; return b }
        primary = [("previous","backward.end","Previous (Page Up)"),("stop","stop","Stop"),("play","play.fill","Play / pause (Space)"),("next","forward.end","Next (Page Down)"),("compact","pip","Mini player (P)")].map { key,symbol,help in let b = button(key,"",symbol:symbol,help:help,parent:controls); b.flat = key != "play"; b.accent = key == "play"; return b }
        _ = button("mute","",symbol:"speaker.wave.2",help:"Mute (M)",parent:controls); _ = button("fullscreen","",symbol:"arrow.up.left.and.arrow.down.right",help:"Fullscreen (F)",parent:controls)
        for pop in [audio,subtitles,aspect,videoSize,speed] { pop.font = .systemFont(ofSize:11); pop.bezelStyle = .rounded; pop.contentTintColor = Palette.text }
        audio.addItem(withTitle:"Default audio"); subtitles.addItem(withTitle:"Subtitles off")
        aspect.addItems(withTitles:["Original","16:9","16:10","4:3","1:1","21:9"]); videoSize.addItems(withTitles:["Half size (50%)","Original size (100%)","Double size (200%)"]); videoSize.selectItem(at:1)
        speed.addItems(withTitles:["0.50×","0.75×","0.90×","1.00×","1.25×","1.50×","2.00×"]); speed.selectItem(at:3)
        for (v,name) in [(audio,"Audio track"),(subtitles,"Subtitle track"),(aspect,"Aspect ratio"),(videoSize,"Video size"),(speed,"Playback speed")] { v.setAccessibilityLabel(name) }
        timeline.setAccessibilityLabel("Playback position"); volume.setAccessibilityLabel("Volume"); timeline.isContinuous = true; volume.isContinuous = true; timeline.controlSize = .small; volume.controlSize = .small
        inspector.addSubview(inspectorScroll); inspectorScroll.documentView = inspectorBody; inspectorScroll.hasVerticalScroller = true; inspectorScroll.drawsBackground = false
        for v in [now,artwork,nowTitle,nowSource,format,resolution,rateBadge,backend,audio,subtitles,aspect,videoSize] { inspectorBody.addSubview(v) }
        nowTitle.maximumNumberOfLines = 2; nowTitle.lineBreakMode = .byWordWrapping
        _ = button("hideInspector","",symbol:"chevron.right",parent:inspectorBody)
        for (key,title) in [("loadSubtitle","Load external subtitle"),("rotate","Rotate 90°"),("mini","Mini player"),("prevChapter","Previous"),("nextChapter","Next"),("discMenu","DVD menu")] { _ = button(key,title,parent:inspectorBody) }
        for text in ["TRACKS","Audio","Subtitles","VIEW","Video size","Aspect ratio","CHAPTERS","Original preserves the video's proportions."] { let v = text == text.uppercased() ? section(text) : label(text,10,color:Palette.muted); inspectorLabels.append(v); inspectorBody.addSubview(v) }
        footer.addSubview(status); footer.addSubview(shortcut)
        layer?.borderColor = Palette.line.cgColor; layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:nil) as? [URL] ?? []
        guard !urls.isEmpty else { return false }; video.drop?(urls); return true
    }
    @discardableResult func button(_ key: String,_ title: String,symbol: String? = nil,help: String = "",parent: NSView) -> ActionButton {
        let b = ActionButton(title,symbol:symbol,help:help) { [weak self] in self?.action?(key) }; buttons[key] = b; parent.addSubview(b); return b
    }
    override func layout() {
        super.layout(); let w = bounds.width, h = bounds.height
        let headerHeight: CGFloat = compact ? 38 : 50, footerHeight: CGFloat = compact ? 0 : 28
        let left: CGFloat = showSidebar && !compact ? 246 : 0, right: CGFloat = showInspector && !compact ? 280 : 0
        header.frame = NSRect(x:0,y:0,width:w,height:headerHeight); footer.frame = NSRect(x:0,y:h-footerHeight,width:w,height:footerHeight); footer.isHidden = compact
        sidebar.frame = NSRect(x:0,y:headerHeight,width:left,height:h-headerHeight-footerHeight); sidebar.isHidden = left == 0
        inspector.frame = NSRect(x:w-right,y:headerHeight,width:right,height:h-headerHeight-footerHeight); inspector.isHidden = right == 0
        center.frame = NSRect(x:left,y:headerHeight,width:w-left-right,height:h-headerHeight-footerHeight)
        logo.frame = NSRect(x:84,y:13,width:24,height:24); brand.frame = NSRect(x:116,y:17,width:68,height:20); badge.frame = NSRect(x:185,y:20,width:45,height:16)
        for v in [logo,brand,badge] { v.isHidden = compact }
        title.frame = NSRect(x:compact ? 84 : 245,y:compact ? 11 : 17,width:max(0,w-(compact ? 365 : 610)),height:20); title.alignment = .center
        buttons["open"]?.frame = NSRect(x:w-330,y:9,width:74,height:32); buttons["inspector"]?.frame = NSRect(x:w-248,y:9,width:190,height:32); buttons["settings"]?.frame = NSRect(x:w-46,y:9,width:32,height:32)
        buttons["open"]?.isHidden = compact; buttons["inspector"]?.isHidden = compact; buttons["settings"]?.isHidden = compact
        sourceLabel.frame = NSRect(x:22,y:18,width:180,height:14)
        for (index,b) in sourceButtons.enumerated() { b.frame = NSRect(x:14,y:40+CGFloat(index)*36,width:218,height:32) }
        search.frame = NSRect(x:14,y:234,width:218,height:30); queueLabel.frame = NSRect(x:22,y:279,width:100,height:14); queueCount.frame = NSRect(x:132,y:279,width:92,height:14); queueCount.alignment = .right
        let qh = max(20,sidebar.bounds.height-350)
        queueScroll.frame = NSRect(x:8,y:301,width:230,height:qh); table.tableColumns.first?.width = 225
        emptyQueue.frame = NSRect(x:14,y:301+qh/2-24,width:218,height:50)
        buttons["save"]?.frame = NSRect(x:14,y:sidebar.bounds.height-44,width:132,height:32); buttons["remove"]?.frame = NSRect(x:154,y:sidebar.bounds.height-44,width:34,height:32); buttons["clear"]?.frame = NSRect(x:196,y:sidebar.bounds.height-44,width:34,height:32)
        let cw = center.bounds.width, ch = center.bounds.height, tall = cw < 810
        let controlHeight: CGFloat = compact ? 78 : tall ? 150 : 108
        video.frame = NSRect(x:compact ? 0 : 12,y:compact ? 0 : 12,width:cw-(compact ? 0 : 24),height:max(40,ch-controlHeight-(compact ? 0 : 12)))
        controls.frame = NSRect(x:0,y:ch-controlHeight,width:cw,height:controlHeight)
        elapsed.frame = NSRect(x:18,y:12,width:46,height:16); remaining.frame = NSRect(x:cw-66,y:12,width:48,height:16); timeline.frame = NSRect(x:68,y:10,width:max(20,cw-136),height:20)
        let py: CGFloat = compact ? 32 : 43
        let total: CGFloat = 220
        for (i,b) in primary.enumerated() { b.frame = NSRect(x:(cw-total)/2+CGFloat(i)*44,y:py,width:40,height:compact ? 38 : 48) }
        for (i,b) in tools.enumerated() { b.frame = NSRect(x:16+CGFloat(i)*36,y:tall ? 105 : 49,width:32,height:32); b.isHidden = compact }
        speed.frame = NSRect(x:cw-242,y:tall ? 108 : 51,width:70,height:28)
        buttons["mute"]?.frame = NSRect(x:cw-168,y:tall ? 105 : 49,width:32,height:32); volume.frame = NSRect(x:cw-130,y:tall ? 111 : 55,width:78,height:20); buttons["fullscreen"]?.frame = NSRect(x:cw-44,y:tall ? 105 : 49,width:30,height:32)
        for v in [speed,volume,buttons["mute"]!,buttons["fullscreen"]!] { v.isHidden = compact }
        let vw = video.bounds.width, vh = video.bounds.height
        buttons["emptyOpen"]?.frame = NSRect(x:vw/2-41,y:vh/2-86,width:82,height:82)
        video.empty.subviews.first(where: { $0.identifier?.rawValue == "headline" })?.frame = NSRect(x:8,y:vh/2+18,width:vw-16,height:26)
        video.empty.subviews.first(where: { $0.identifier?.rawValue == "subhead" })?.frame = NSRect(x:8,y:vh/2+53,width:vw-16,height:22)
        notice.frame = NSRect(x:20,y:28,width:max(20,cw-40),height:34)
        inspectorScroll.frame = inspector.bounds; inspectorBody.frame = NSRect(x:0,y:0,width:280,height:max(850,inspector.bounds.height))
        now.frame = NSRect(x:18,y:23,width:200,height:14); buttons["hideInspector"]?.frame = NSRect(x:234,y:15,width:28,height:28)
        artwork.frame = NSRect(x:18,y:58,width:244,height:142); nowTitle.frame = NSRect(x:18,y:216,width:244,height:48); nowSource.frame = NSRect(x:18,y:266,width:244,height:18)
        format.frame = NSRect(x:18,y:296,width:80,height:16); resolution.frame = NSRect(x:103,y:296,width:95,height:16); rateBadge.frame = NSRect(x:210,y:296,width:52,height:16); backend.frame = NSRect(x:18,y:319,width:244,height:16)
        let positions: [CGFloat] = [358,385,450,565,591,655,774,721]
        for (index,v) in inspectorLabels.enumerated() { v.frame = NSRect(x:18,y:positions[index],width:244,height:16) }
        audio.frame = NSRect(x:16,y:406,width:248,height:28); subtitles.frame = NSRect(x:16,y:471,width:248,height:28)
        buttons["loadSubtitle"]?.frame = NSRect(x:18,y:512,width:244,height:30)
        videoSize.frame = NSRect(x:16,y:612,width:248,height:28); aspect.frame = NSRect(x:16,y:676,width:248,height:28)
        buttons["rotate"]?.frame = NSRect(x:18,y:740,width:118,height:28); buttons["mini"]?.frame = NSRect(x:144,y:740,width:118,height:28)
        buttons["prevChapter"]?.frame = NSRect(x:18,y:798,width:118,height:28); buttons["nextChapter"]?.frame = NSRect(x:144,y:798,width:118,height:28)
        buttons["discMenu"]?.frame = NSRect(x:18,y:838,width:244,height:28); inspectorBody.setFrameSize(NSSize(width:280,height:max(884,inspector.bounds.height)))
        status.frame = NSRect(x:12,y:6,width:max(100,w/2),height:16); shortcut.frame = NSRect(x:w-350,y:6,width:338,height:16); shortcut.alignment = .right
    }
    func sync(_ info: PlaybackInfo,_ source: MediaSource?, backend engine: String, settings: Preferences) {
        title.stringValue = source?.title ?? "Ready for a film"; nowTitle.stringValue = source?.title ?? "Nothing queued"; nowSource.stringValue = source?.url.path ?? "Choose a source to begin"; nowSource.toolTip = source?.url.absoluteString
        format.stringValue = source?.kind ?? "READY"; resolution.stringValue = info.size.width > 0 ? "\(Int(info.size.width)) × \(Int(info.size.height))" : "—"; rateBadge.stringValue = String(format:"%.2f×",settings.rate); backend.stringValue = engine
        elapsed.stringValue = clockText(info.time); remaining.stringValue = "−"+clockText(max(0,info.duration-info.time))
        if !(window?.currentEvent?.type == .leftMouseDragged) { timeline.doubleValue = info.duration > 0 ? info.time/info.duration*1000 : 0 }; timeline.isEnabled = info.duration > 0
        buttons["play"]?.image = NSImage(systemSymbolName:info.playing ? "pause.fill" : "play.fill",accessibilityDescription:info.playing ? "Pause" : "Play")
        buttons["mute"]?.image = NSImage(systemSymbolName:settings.muted ? "speaker.slash" : "speaker.wave.2",accessibilityDescription:"Mute")
        buttons["shuffle"]?.selected = settings.shuffle; buttons["shuffle"]?.needsDisplay = true
        buttons["repeat"]?.selected = settings.repeatMode != 0; buttons["repeat"]?.image = NSImage(systemSymbolName:settings.repeatMode == 2 ? "repeat.1" : "repeat",accessibilityDescription:"Repeat"); buttons["repeat"]?.toolTip = "Repeat: \(["Off","All","One"][min(2,max(0,settings.repeatMode))]) (R)"; buttons["repeat"]?.needsDisplay = true
        volume.doubleValue = settings.volume
        status.stringValue = "●  \(info.status)" + (source != nil ? "  ·  \(engine)" : "")
        func populate(_ pop: NSPopUpButton,_ choices: [TrackChoice],_ selected: Int) {
            let old = pop.itemArray.map { TrackChoice(id:$0.tag,title:$0.title) }
            // addItem(withTitle:) removes an existing item with the same title, so two "English"
            // tracks would collapse into one. Add menu items directly instead.
            if old != choices { pop.removeAllItems(); for t in choices { let item = NSMenuItem(title:t.title,action:nil,keyEquivalent:""); item.tag = t.id; pop.menu?.addItem(item) } }
            pop.selectItem(withTag:selected)
        }
        populate(audio,info.audio.isEmpty ? [TrackChoice(id:0,title:"Default audio")] : info.audio,info.audioID)
        populate(subtitles,info.subtitles.isEmpty ? [TrackChoice(id:-1,title:"Subtitles off")] : info.subtitles,info.subtitleID)
    }
}
