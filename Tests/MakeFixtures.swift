import AppKit
import AVFoundation
let root = URL(fileURLWithPath:CommandLine.arguments[1]); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let width = 320, height = 180
try? FileManager.default.removeItem(at:root.appendingPathComponent("native.mp4"))
let writer = try AVAssetWriter(outputURL:root.appendingPathComponent("native.mp4"),fileType:.mp4)
let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
writer.add(input); guard writer.startWriting() else { fatalError(writer.error?.localizedDescription ?? "Writer unavailable") }; writer.startSession(atSourceTime:.zero)
for frame in 0..<288 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval:0.001) }
    var buffer: CVPixelBuffer?; CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32ARGB,nil,&buffer)
    CVPixelBufferLockBaseAddress(buffer!,[])
    let context = CGContext(data:CVPixelBufferGetBaseAddress(buffer!),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer!),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let colors: [(CGFloat,CGFloat,CGFloat)] = [(0.75,0.12,0.16),(0.12,0.7,0.22),(0.13,0.24,0.8),(0.8,0.65,0.1)]
    for (i,c) in colors.enumerated() { context.setFillColor(CGColor(red:c.0,green:c.1,blue:c.2,alpha:1)); context.fill(CGRect(x:i*80,y:0,width:80,height:height)) }
    context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:frame%280,y:75,width:40,height:30))
    if frame == 0, let image = context.makeImage() { let rep = NSBitmapImageRep(cgImage:image); try rep.representation(using:.jpeg,properties:[.compressionFactor:0.9])!.write(to:root.appendingPathComponent("frame.jpg")) }
    CVPixelBufferUnlockBaseAddress(buffer!,[])
    adaptor.append(buffer!,withPresentationTime:CMTime(value:Int64(frame),timescale:24))
}
input.markAsFinished(); let done = DispatchSemaphore(value:0); writer.finishWriting { done.signal() }; done.wait()
guard writer.status == .completed else { fatalError(writer.error!.localizedDescription) }
try "1\n00:00:00,000 --> 00:00:11,900\nNOIR native captions\n".write(to:root.appendingPathComponent("plain.srt"),atomically:true,encoding:.utf8)
try "1\n00:00:00,000 --> 00:00:11,900\n<b>NOIR styled captions</b>\n".write(to:root.appendingPathComponent("styled.srt"),atomically:true,encoding:.utf8)
