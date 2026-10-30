import AppKit
import DiskArbitration
import IOKit

struct OpticalDevice: Equatable {
    let volume: URL?
    let bsdName: String
    let registryID: UInt64
    var title: String { volume?.lastPathComponent ?? bsdName }

    static func inspect(_ volume: URL) -> OpticalDevice? {
        guard let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil,session,volume as CFURL) else { return nil }
        return inspect(disk)
    }
    static func inspect(bsdName: String) -> OpticalDevice? {
        guard let session = DASessionCreate(nil),let disk = DADiskCreateFromBSDName(nil,session,bsdName) else { return nil }
        return inspect(disk)
    }
    private static func inspect(_ disk: DADisk) -> OpticalDevice? {
        guard let whole = DADiskCopyWholeDisk(disk) else { return nil }
        let media = DADiskCopyIOMedia(whole)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        // Removable/ejectable also describes USB and SD storage. Require the
        // whole device's actual optical I/O Registry class instead.
        guard isOptical(media),
              let name = DADiskGetBSDName(whole) else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media,&registryID) == KERN_SUCCESS else { return nil }
        let description = DADiskCopyDescription(disk) as? [String:Any]
        let volume = description?[kDADiskDescriptionVolumePathKey as String] as? URL
        return OpticalDevice(volume:volume,bsdName:String(cString:name),registryID:registryID)
    }
    private static func isOptical(_ media: io_service_t) -> Bool {
        ["IOCDMedia","IODVDMedia","IOBDMedia"].contains { name in name.withCString { IOObjectConformsTo(media,$0) != 0 } }
    }
    static func available() -> [OpticalDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOMedia"),&iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [OpticalDevice] = [], seen = Set<UInt64>()
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            guard isOptical(media),let name = IORegistryEntryCreateCFProperty(media,"BSD Name" as CFString,nil,0)?.takeRetainedValue() as? String,
                  let device = inspect(bsdName:name),seen.insert(device.registryID).inserted else { continue }
            result.append(device)
        }
        return result.sorted { $0.bsdName < $1.bsdName }
    }
}

struct DiscEjector {
    var inspect: (OpticalDevice)->OpticalDevice? = { OpticalDevice.inspect(bsdName:$0.bsdName) }
    var unmount: (OpticalDevice)throws->Void = Self.systemEject
    var available: ()->[OpticalDevice] = OpticalDevice.available
    var locate: (MediaSource)->OpticalDevice? = Self.deviceContaining

    func target(for source: MediaSource) -> OpticalDevice? {
        locate(source)
    }
    private static func deviceContaining(_ source: MediaSource) -> OpticalDevice? {
        guard let folder = source.localDiscURL ?? (source.url.isFileURL ? source.url : nil) else { return nil }
        if folder.path.hasPrefix("/dev/") {
            let name = folder.lastPathComponent
            return OpticalDevice.inspect(bsdName:name.hasPrefix("rdisk") ? String(name.dropFirst()) : name)
        }
        let volume = (try? folder.resourceValues(forKeys:[.volumeURLKey]))?.volume ?? folder
        return OpticalDevice.inspect(volume)
    }
    func contains(_ source: MediaSource,on device: OpticalDevice) -> Bool {
        guard let playing = target(for:source) else { return false }
        return playing.registryID == device.registryID && playing.bsdName == device.bsdName
    }
    /// Prefer the playing/selected disc, then an unambiguous optical device.
    /// Include media which macOS has not mounted successfully.
    func targets(preferred: [MediaSource]) -> [OpticalDevice] {
        let devices = available()
        for source in preferred {
            if let target = target(for:source),let match = devices.first(where: { $0.registryID == target.registryID && $0.bsdName == target.bsdName }) {
                // Whole optical media may have no mount URL when a child partition
                // holds the filesystem. Keep that path for release/queue cleanup.
                return [OpticalDevice(volume:target.volume ?? match.volume,bsdName:match.bsdName,registryID:match.registryID)]
            }
        }
        return devices
    }

    func eject(_ device: OpticalDevice) throws {
        // Recheck after playback releases its handles: a volume may have been
        // removed or replaced while the decoder was stopping.
        guard let current = inspect(device),current.bsdName == device.bsdName,current.registryID == device.registryID else { throw NoirError.message("The optical disc changed before it could be ejected.") }
        try unmount(current)
    }
    private static func systemEject(_ device: OpticalDevice) throws {
        // Disk Arbitration releases all volumes before ejecting the whole device.
        // Use the verified BSD identity so no mounted URL is required. Never force it.
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value:0)
        process.executableURL = URL(fileURLWithPath:"/usr/sbin/diskutil")
        process.arguments = ["eject","/dev/"+device.bsdName]
        process.standardOutput = output; process.standardError = output
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout:.now()+25) == .success else {
            process.terminate()
            throw NoirError.message("The optical drive did not respond within 25 seconds. Close any other app using the disc and try again.")
        }
        let message = String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw NoirError.message(message.isEmpty ? "macOS could not eject the optical disc." : message) }
    }
}
