import Foundation
import CoreML
import AppKit

// Simple diagnostics runner to isolate where grayscale output occurs.

struct Stats { let min: Float; let max: Float; let mean: Float; let std: Float }

func stats(_ arr: MLMultiArray, sample: Int = 0) -> Stats {
    var mn = Float.greatestFiniteMagnitude
    var mx = -Float.greatestFiniteMagnitude
    var sum: Double = 0
    var sum2: Double = 0
    let n = arr.count
    for i in 0..<n {
        let v = arr[i].floatValue
        if v < mn { mn = v }
        if v > mx { mx = v }
        sum += Double(v)
        sum2 += Double(v)*Double(v)
    }
    let mean = Float(sum / Double(n))
    let varf = Float(max(0, sum2/Double(n) - (sum/Double(n))*(sum/Double(n))))
    return Stats(min: mn, max: mx, mean: mean, std: sqrt(varf))
}

func projectRoot() -> URL {
    let fm = FileManager.default
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
    let candidates = [
        cwd,
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/MaccyScaler"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/coding/MaccyScaler")
    ]
    for c in candidates {
        if fm.fileExists(atPath: c.appendingPathComponent("FastDVDnet.mlpackage").path) ||
           fm.fileExists(atPath: c.appendingPathComponent("RealBasicVSR_x2.mlpackage").path) {
            return c
        }
    }
    return cwd
}

func loadModel(_ name: String) throws -> MLModel {
    let base = projectRoot()
    let url = base.appendingPathComponent(name)
    if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
        let compiled = try MLModel.compileModel(at: url)
        return try MLModel(contentsOf: compiled)
    }
    return try MLModel(contentsOf: url)
}

func nsImageToArray(_ image: NSImage, size: Int = 256) -> MLMultiArray? {
    let target = CGSize(width: size, height: size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8, bytesPerRow: Int(target.width) * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(in: NSRect(origin: .zero, size: NSSize(width: target.width, height: target.height)))
    NSGraphicsContext.restoreGraphicsState()
    guard let buf = ctx.data else { return nil }
    guard let arr = try? MLMultiArray(shape: [1,3,NSNumber(value:size),NSNumber(value:size)], dataType: .float32) else { return nil }
    let ptr = buf.bindMemory(to: UInt8.self, capacity: Int(target.width*target.height*4))
    for y in 0..<size {
        for x in 0..<size {
            let si = (y*size + x)*4
            let r = Float(ptr[si+0]) / 255.0
            let g = Float(ptr[si+1]) / 255.0
            let b = Float(ptr[si+2]) / 255.0
            arr[0*size*size + y*size + x] = NSNumber(value: r)
            arr[1*size*size + y*size + x] = NSNumber(value: g)
            arr[2*size*size + y*size + x] = NSNumber(value: b)
        }
    }
    return arr
}

func gradientImage(size: Int = 256) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    for y in 0..<size {
        for x in 0..<size {
            let r = CGFloat(x) / CGFloat(size)
            let g = CGFloat(y) / CGFloat(size)
            let b = CGFloat((x+y) % size) / CGFloat(size)
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: 1, height: 1)).fill()
        }
    }
    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, to url: URL) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

func ffmpegPath() -> String { ["/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg","/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/ffmpeg" }

func extractFrames(from video: String, count: Int, to dir: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent("diag_%05d.png").path
    let p = Process(); p.launchPath = ffmpegPath()
    p.arguments = ["-hide_banner","-y","-v","error","-i", video, "-vf","scale=256:256:flags=lanczos,fps=2","-frames:v","\(count)", out]
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain:"Diag", code:1, userInfo:[NSLocalizedDescriptionKey:"FFmpeg failed"]) }
    return (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)).sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func buildWindow(from images: [NSImage], index i: Int) -> [NSImage] {
    var win: [NSImage] = []
    let n = images.count
    for j in -2...2 {
        let idx = max(0, min(n-1, i+j))
        win.append(images[idx])
    }
    return win
}

func runDiagnostics(videoPath: String?) throws {
    print("=== MaccyScaler Diagnostics ===")
    let base = projectRoot()
    print("Project root: \(base.path)")
    let fast = try loadModel("FastDVDnet.mlpackage")
    let rbv = try loadModel("RealBasicVSR_x2.mlpackage")
    print("Loaded models.")
    let outDir = base.appendingPathComponent("diagnostics_out")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    
    var frames: [NSImage] = []
    if let videoPath = videoPath {
        print("Extracting frames from: \(videoPath)")
        let temp = base.appendingPathComponent(".diag_tmp_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let urls = try extractFrames(from: videoPath, count: 5, to: temp)
        for u in urls { if let img = NSImage(contentsOf: u) { frames.append(img) } }
    } else {
        for _ in 0..<5 { frames.append(gradientImage()) }
    }
    if frames.count < 1 { print("No frames for diagnostics"); return }
    
    // Build 5-frame window around the first frame (clamped)
    let winImgs = buildWindow(from: frames, index: 0)
    var window: [MLMultiArray] = []
    for img in winImgs { if let arr = nsImageToArray(img) { window.append(arr) } }
    guard window.count == 5 else { print("Could not build 5-frame window"); return }
    
    // Pack into [1,15,256,256]
    guard let input = try? MLMultiArray(shape: [1,15,256,256], dataType: .float32) else { print("alloc fail"); return }
    for f in 0..<5 { for c in 0..<3 { for i in 0..<(256*256) {
        input[f*3*256*256 + c*256*256 + i] = window[f][c*256*256 + i]
    }}}
    let inputProv = try MLDictionaryFeatureProvider(dictionary: ["x_9": MLFeatureValue(multiArray: input)])
    let outFast = try fast.prediction(from: inputProv)
    guard let denArr = outFast.featureValue(for: "var_979")?.multiArrayValue else { print("FastDVDnet no output"); return }
    let s1 = stats(denArr)
    print(String(format: "FastDVDnet stats: min=%.4f max=%.4f mean=%.4f std=%.4f", s1.min, s1.max, s1.mean, s1.std))
    
    // Prepare RBV input (layout adapt if needed)
    var rbvInput = denArr
    if let c = rbv.modelDescription.inputDescriptionsByName["x_1"]?.multiArrayConstraint {
        let shp = c.shape.map{$0.intValue}
        if shp.count == 4, let ch = (0..<4).first(where: { shp[$0] == 3 }) {
            if ch == 3 {
                // NHWC expected
                if let dst = try? MLMultiArray(shape:[1,256,256,3], dataType:.float32) {
                    for y in 0..<256 { for x in 0..<256 { for c in 0..<3 {
                        let srcOff = c*256*256 + y*256 + x
                        let dstOff = y*256*3 + x*3 + c
                        dst[dstOff] = denArr[srcOff]
                    }}}
                    rbvInput = dst
                }
            }
        }
    }
    let rbvProv = try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: rbvInput)])
    let outRBV = try rbv.prediction(from: rbvProv)
    guard let up = outRBV.featureValue(for: "var_867")?.multiArrayValue else { print("RBV no output"); return }
    let s2 = stats(up)
    print(String(format: "RBV stats: min=%.4f max=%.4f mean=%.4f std=%.4f", s2.min, s2.max, s2.mean, s2.std))
    
    // Save debug PNGs
    func arrayToImageNCHW(_ a: MLMultiArray) -> NSImage? {
        let shp = a.shape.map{ $0.intValue }
        if shp.count != 4 { return nil }
        var w = 0, h = 0
        if shp[1] == 3 { h = shp[2]; w = shp[3] } else if shp[3] == 3 { h = shp[1]; w = shp[2] } else { return nil }
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        if shp[1] == 3 {
            for y in 0..<h { for x in 0..<w {
                let p = (y*w+x)*4
                let r = a[0*h*w + y*w + x].floatValue
                let g = a[1*h*w + y*w + x].floatValue
                let b = a[2*h*w + y*w + x].floatValue
                pixels[p] = UInt8(max(0,min(255, Int(r*255))))
                pixels[p+1] = UInt8(max(0,min(255, Int(g*255))))
                pixels[p+2] = UInt8(max(0,min(255, Int(b*255))))
                pixels[p+3] = 255
            }}
        } else {
            for y in 0..<h { for x in 0..<w {
                let p = (y*w+x)*4
                let r = a[(y*w*3)+(x*3)+0].floatValue
                let g = a[(y*w*3)+(x*3)+1].floatValue
                let b = a[(y*w*3)+(x*3)+2].floatValue
                pixels[p] = UInt8(max(0,min(255, Int(r*255))))
                pixels[p+1] = UInt8(max(0,min(255, Int(g*255))))
                pixels[p+2] = UInt8(max(0,min(255, Int(b*255))))
                pixels[p+3] = 255
            }}
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
    if let img1 = arrayToImageNCHW(denArr) { savePNG(img1, to: outDir.appendingPathComponent("denoised.png")) }
    if let img2 = arrayToImageNCHW(up) { savePNG(img2, to: outDir.appendingPathComponent("upscaled.png")) }
    
    if s1.std < 1e-5 { print("WARNING: Denoised output nearly constant — check FastDVDnet input mapping") }
    if s2.std < 1e-5 { print("WARNING: RBV output nearly constant — check RBV input layout/range") }
    print("Diagnostics done. Outputs in diagnostics_out/")
}

func main() throws {
    var video: String? = nil
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        if a == "--video", let p = it.next() { video = p }
    }
    try runDiagnostics(videoPath: video)
}

do { try main() } catch { print("Diagnostics error: \(error)") }
