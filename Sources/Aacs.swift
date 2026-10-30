import Foundation
import Darwin

enum AacsRuntime {
    private(set) static var libraryPath: String?
    private(set) static var status = "AACS library unavailable"
    // Keep the validated image mapped for libbluray's later dlopen.
    private static var handle: UnsafeMutableRawPointer?
    static func initialize(configured: String) {
        setenv("AACS_CONFIG_DIR",AacsKeys.folder.path,1)
        // Upstream macOS libaacs uses AACS_HOME as the parent of its aacs folder.
        setenv("AACS_HOME",AacsKeys.folder.deletingLastPathComponent().path,1)
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/AACS/libaacs.dylib").path
        var errors: [String] = []
        for path in [configured,bundled,"/opt/homebrew/lib/libaacs.dylib","/usr/local/lib/libaacs.dylib"] where !path.isEmpty {
            guard FileManager.default.fileExists(atPath:path) else { continue }
            guard let loaded = dlopen(path,RTLD_NOW | RTLD_LOCAL) else {
                errors.append(dlerror().map { String(cString:$0) } ?? "Library could not load"); continue
            }
            guard dlsym(loaded,"aacs_open") != nil,dlsym(loaded,"aacs_close") != nil else { dlclose(loaded); errors.append("The selected library has no AACS entry points."); continue }
            handle = loaded; libraryPath = path
            // libbluray's macOS loader appends .dylib, unlike the Windows DLL
            // loader. Passing the full filename makes it try .dylib.dylib.
            setenv("LIBAACS_PATH",URL(fileURLWithPath:path).deletingPathExtension().path,1)
            status = path == bundled ? "Bundled AACS runtime ready" : "External AACS runtime ready"; return
        }
        status = errors.isEmpty ? "AACS library unavailable" : "AACS library could not load"
        errors.forEach { NSLog("NOIR AACS: %@",$0) }
    }
}

enum AacsKeys {
    static var folder: URL {
        if ProcessInfo.processInfo.environment["NOIR_DATA_DIR"] != nil { return Preferences.directory.appendingPathComponent("aacs") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/aacs")
    }
    static func validateInstalled(in directory: URL? = nil) throws {
        let url = (directory ?? folder).appendingPathComponent("KEYDB.cfg")
        guard let size = (try? FileManager.default.attributesOfItem(atPath:url.path))?[.size] as? Int,
              size > 0,size <= 256*1024*1024,let file = try? FileHandle(forReadingFrom:url) else {
            throw NoirError.message("AACS key database is missing. Use Settings → Download AACS keys, or place a compatible KEYDB.cfg in \(folder.path).")
        }
        defer { try? file.close() }
        let head = try file.read(upToCount:4*1024*1024) ?? Data()
        guard !head.starts(with:[0x50,0x4b]),(0...min(3,head.count)).contains(where: { (try? database(Data(head.dropLast($0)))) != nil }) else {
            throw NoirError.message("AACS KEYDB.cfg is compressed or invalid. Download or install a valid plaintext key database in Settings.")
        }
    }
    static func database(_ input: Data) throws -> Data {
        guard input.count <= 128*1024*1024 else { throw NoirError.message("Key download exceeds 128 MB.") }
        var data = input
        if input.starts(with:[0x50,0x4b]) { data = try unzip(input) }
        // Only the first 4 MB is inspected; when that cut splits a multi-byte character, drop its partial bytes.
        let head = data.prefix(4*1024*1024), partial = head.count < data.count ? 3 : 0
        let text = (0...partial).lazy.compactMap { String(data:head.dropLast($0),encoding:.utf8) }.first
        guard !data.isEmpty, data.count <= 256*1024*1024, let text, !text.lowercased().contains("<html"), text.contains("|"),
              text.contains("=") || text.range(of:#"(?m)^[ \t]*\|[ \t]*(?:PK|DK|HC)[ \t]*\|"#,options:.regularExpression) != nil else {
            throw NoirError.message("The server did not return a valid plaintext KEYDB.cfg.")
        }
        return data
    }
    // Read just one validated ZIP member into memory. No archive paths are extracted.
    static func unzip(_ data: Data) throws -> Data {
        func bad() -> NoirError { .message("The key database ZIP is invalid or unsupported.") }
        func u16(_ n: Int) throws -> Int { guard n>=0,n+2<=data.count else { throw bad() }; return Int(data[n]) | Int(data[n+1])<<8 }
        func u32(_ n: Int) throws -> Int { try u16(n) | u16(n+2)<<16 }
        guard data.count >= 22 else { throw bad() }
        var end: Int?
        for n in stride(from:data.count-22,through:max(0,data.count-65557),by:-1) {
            if try u32(n) == 0x06054b50, n+22+(try u16(n+20)) == data.count { end=n; break }
        }
        guard let end, try u16(end+4)==0, try u16(end+6)==0 else { throw bad() }
        let count=try u16(end+10), central=try u32(end+16), centralSize=try u32(end+12)
        guard count<=10_000, try u16(end+8)==count, central+centralSize==end else { throw bad() }
        var offset=central, matches: [(Int,Int,Int,Int,Int,Int,String)]=[]
        for _ in 0..<count {
            guard try u32(offset)==0x02014b50 else { throw bad() }
            let flags=try u16(offset+8), method=try u16(offset+10), crc=try u32(offset+16), compressed=try u32(offset+20), size=try u32(offset+24), nameLength=try u16(offset+28), extra=try u16(offset+30), comment=try u16(offset+32), local=try u32(offset+42)
            guard offset+46+nameLength+extra+comment<=end else { throw bad() }
            guard let name=String(data:data[(offset+46)..<(offset+46+nameLength)],encoding:.utf8) else { throw bad() }
            if name.split(separator:"/").last?.lowercased()=="keydb.cfg" { matches.append((flags,method,crc,compressed,size,local,name)) }
            offset += 46+nameLength+extra+comment
        }
        guard offset==end,matches.count==1 else { throw NoirError.message("The archive must contain exactly one KEYDB.cfg.") }
        let (flags,method,crc,compressed,size,local,name)=matches[0]
        guard flags&1==0,[0,8].contains(method),size>0,size<=256*1024*1024,compressed<=128*1024*1024,try u32(local)==0x04034b50,try u16(local+8)==method,try u16(local+6)==flags else { throw bad() }
        let localName=try u16(local+26), localExtra=try u16(local+28), start=local+30+localName+localExtra
        guard start<=central,start+compressed<=central,local+30+localName<=data.count,String(data:data[(local+30)..<(local+30+localName)],encoding:.utf8)==name else { throw bad() }
        let payload=Data(data[start..<(start+compressed)])
        if method==0 { guard payload.count==size,payload.withUnsafeBytes({ noir_crc32($0.baseAddress,UInt32(size)) })==UInt32(crc) else { throw bad() }; return payload }
        var result=Data(count:size)
        let valid=payload.withUnsafeBytes { source in result.withUnsafeMutableBytes { destination in noir_inflate(source.baseAddress,UInt32(compressed),destination.baseAddress,UInt32(size),UInt32(crc)) } }
        guard valid==0 else { throw bad() }; return result
    }
}
final class KeyDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?, data=Data(), redirects=0, finished=false
    private let completion: (Result<Data,Error>)->Void
    init(completion: @escaping (Result<Data,Error>)->Void) { self.completion=completion }
    func start() {
        let config=URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest=60; config.timeoutIntervalForResource=60; config.httpAdditionalHeaders=["User-Agent":"NoirMediaPlayer/1.0 macOS"]
        session=URLSession(configuration:config,delegate:self,delegateQueue:.main)
        session?.dataTask(with:URL(string:"https://fvonline-db.bplaced.net/fv_download.php?lang=eng")!).resume()
    }
    private func finish(_ result: Result<Data,Error>) { guard !finished else { return }; finished=true; session?.invalidateAndCancel(); session=nil; completion(result) }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,completionHandler: @escaping (URLSession.ResponseDisposition)->Void) {
        guard let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode),response.url?.scheme=="https",response.expectedContentLength<=128*1024*1024 else { completionHandler(.cancel); finish(.failure(NoirError.message("The key server returned an invalid or oversized response."))); return }; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive newData: Data) {
        guard data.count+newData.count<=128*1024*1024 else { finish(.failure(NoirError.message("Key download exceeds 128 MB."))); return }; data.append(newData)
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?)->Void) {
        redirects += 1; guard redirects<=3,request.url?.scheme=="https" else { completionHandler(nil); finish(.failure(NoirError.message("Key server redirected to an unsupported destination."))); return }; completionHandler(request)
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } else { finish(.success(data)) } }
}
