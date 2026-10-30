import AppKit
import DiskArbitration
import IOKit

struct OpticalDevice: Equatable {
    let volume: URL
    let bsdName: String
    let registryID: UInt64

    static func inspect(_ volume: URL) -> OpticalDevice? {
        guard let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil,session,volume as CFURL),
              let whole = DADiskCopyWholeDisk(disk) else { return nil }
        let media = DADiskCopyIOMedia(whole)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        // Removable/ejectable also describes USB and SD storage. Require the
        // whole device's actual optical I/O Registry class instead.
        guard ["IOCDMedia","IODVDMedia","IOBDMedia"].contains(where: { name in name.withCString { IOObjectConformsTo(media,$0) != 0 } }),
              let name = DADiskGetBSDName(whole) else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media,&registryID) == KERN_SUCCESS else { return nil }
        return OpticalDevice(volume:volume,bsdName:String(cString:name),registryID:registryID)
    }
}

struct DiscEjector {
    var inspect: (URL)->OpticalDevice? = OpticalDevice.inspect
    var unmount: (URL)throws->Void = { try NSWorkspace.shared.unmountAndEjectDevice(at:$0) }

    func target(for source: MediaSource) -> OpticalDevice? {
        guard let folder = source.localDiscURL,
              let values = try? folder.resourceValues(forKeys:[.volumeURLKey]),
              let volume = values.volume else { return nil }
        return inspect(volume)
    }

    func eject(_ device: OpticalDevice) throws {
        // Recheck after playback releases its handles: a volume may have been
        // removed or replaced while the decoder was stopping.
        guard inspect(device.volume) == device else { throw NoirError.message("The optical disc changed before it could be ejected.") }
        try unmount(device.volume)
    }
}
