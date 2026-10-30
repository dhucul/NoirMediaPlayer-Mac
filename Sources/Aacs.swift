import Foundation

enum AacsKeys {
    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/aacs") }
    static func database(_ input: Data) throws -> Data {
        guard input.count <= 128*1024*1024 else { throw NoirError.message("Key download exceeds 128 MB.") }
        var data = input
        if input.starts(with:[0x50,0x4b]) { data = try unzip(input) }
        // Only the first 4 MB is inspected; when that cut splits a multi-byte character, drop its partial bytes.
        let head = data.prefix(4*1024*1024), partial = head.count < data.count ? 3 : 0
        let text = (0...partial).lazy.compactMap { String(data:head.dropLast($0),encoding:.utf8) }.first
        guard !data.isEmpty, data.count <= 256*1024*1024, let text, !text.lowercased().contains("<html"), text.contains("|") && text.contains("=") else { throw NoirError.message("The server did not return a valid plaintext KEYDB.cfg.") }
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
