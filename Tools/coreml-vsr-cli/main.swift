import Foundation
import CoreML
import CoreImage
import AppKit

// Simple CLI to run CoreML FastDVDnet denoising (5-frame window) then x2 SR.
// If RealBasicVSR_x2.mlmodelc is present and accepts single-frame input, use it.

// Reuse a single CIContext to avoid expensive per-frame creation
let gCIContext = CIContext()

struct Args {
    var inputVideo: String = ""
    var modelsDir: String = ""
    var tempDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MaccyScaler_CLI_\(UUID().uuidString)")
    var outputVideo: String? = nil
}

func parseArgs() -> Args? {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--input":
            if let v = it.next() { args.inputVideo = v }
        case "--models":
            if let v = it.next() { args.modelsDir = v }
        case "--tmp":
            if let v = it.next() { args.tempDir = URL(fileURLWithPath: v) }
        case "--output":
            if let v = it.next() { args.outputVideo = v }
        case "-h", "--help":
            print("Usage: coreml-vsr-cli --input <video.mp4> --models <models-coreml-dir> [--tmp <dir>] [--output <out.mp4>]")
            return nil
        default:
            print("Unknown arg: \(a)")
            return nil
        }
    }
    guard !args.inputVideo.isEmpty, !args.modelsDir.isEmpty else {
        print("Usage: coreml-vsr-cli --input <video.mp4> --models <models-coreml-dir> [--tmp <dir>] [--output <out.mp4>]")
        return nil
    }
    return args
}

func ffmpegPath() -> String { 
    let fm = FileManager.default
    for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] { if fm.isExecutableFile(atPath: p) { return p } }
    return "/opt/homebrew/bin/ffmpeg"
}

func ffprobePath() -> String {
    let fm = FileManager.default
    for p in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] { if fm.isExecutableFile(atPath: p) { return p } }
    return "/opt/homebrew/bin/ffprobe"
}

func probeFPS(_ video: String) -> Double {
    // Read r_frame_rate and convert to double
    let p = Process()
    p.launchPath = ffprobePath()
    p.arguments = ["-v","error","-select_streams","v:0","-show_entries","stream=r_frame_rate","-of","default=nokey=1:noprint_wrappers=1", video]
    let out = Pipe(); p.standardOutput = out
    do { try p.run(); p.waitUntilExit() } catch { return 30.0 }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return 30.0 }
    if let slash = s.firstIndex(of: "/") {
        let num = Double(s[..<slash]) ?? 0
        let den = Double(s[s.index(after: slash)...]) ?? 1
        return den != 0 ? max(1.0, num/den) : 30.0
    }
    return Double(s) ?? 30.0
}

func run(_ launchPath: String, _ arguments: [String]) throws {
    let p = Process()
    p.launchPath = launchPath
    p.arguments = arguments
    let err = Pipe(); p.standardError = err
    let out = Pipe(); p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "CoreMLVSRCLI", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Command failed: \(launchPath) \(arguments.joined(separator: " "))\n\n\(e)"])
    }
}

func loadImage(_ url: URL) -> NSBitmapImageRep? {
    guard let img = NSImage(contentsOf: url) else { return nil }
    return img.representations.compactMap { $0 as? NSBitmapImageRep }.first
}

func imageToArrayRGB(_ rep: NSBitmapImageRep) -> (MLMultiArray, Int, Int)? {
    // Fast path: use existing CGImage; fallback to CI conversion once
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var cgImg: CGImage? = nil
    if #available(macOS 10.15, *) {
        cgImg = rep.cgImage
    }
    if cgImg == nil {
        // Fallback: render into RGBA8 once via global CIContext (avoid PNG/TIFF re-encode)
        guard let tiff = rep.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        cgImg = gCIContext.createCGImage(ci, from: rect, format: .RGBA8, colorSpace: colorSpace)
    }
    guard let cg = cgImg else { return nil }
    let bytesPerRow = cg.bytesPerRow
    guard let provider = cg.dataProvider, let cfdata = provider.data else { return nil }
    let ptr = CFDataGetBytePtr(cfdata)!

    let arr = try! MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
    let countHW = height * width
    let out = arr.dataPointer.bindMemory(to: Float32.self, capacity: 3*countHW)
    let rBase = 0
    let gBase = countHW
    let bBase = 2*countHW
    let inv255: Float32 = 1.0/255.0
    for y in 0..<height {
        let rowStart = y * bytesPerRow
        let dstRowBase = y * width
        for x in 0..<width {
            let p = rowStart + x * 4
            let idx = dstRowBase + x
            out[rBase + idx] = Float32(ptr[p + 0]) * inv255
            out[gBase + idx] = Float32(ptr[p + 1]) * inv255
            out[bBase + idx] = Float32(ptr[p + 2]) * inv255
        }
    }
    return (arr, width, height)
}

func arrayToImage(_ arr: MLMultiArray, width: Int, height: Int) -> NSImage? {
    // Expect shape [1,3,H,W]. Auto-scale output range to [0,1] if needed.
    let count = width * height
    let rBase = 0
    let gBase = count
    let bBase = count * 2
    // Probe a small grid to infer range
    var vmin: Float = .greatestFiniteMagnitude
    var vmax: Float = -.greatestFiniteMagnitude
    let stepY = max(1, height/8), stepX = max(1, width/8)
    for y in stride(from: 0, to: height, by: stepY) {
        for x in stride(from: 0, to: width, by: stepX) {
            let i = y*width + x
            let r = arr[rBase + i].floatValue
            let g = arr[gBase + i].floatValue
            let b = arr[bBase + i].floatValue
            vmin = min(vmin, r, g, b)
            vmax = max(vmax, r, g, b)
        }
    }
    // Heuristic scaling: handle [-1,1], [0,1], and [0,255]
    var scale: Float = 1.0
    var bias: Float = 0.0
    if vmax > 2.0 { // looks like [0,255]
        scale = 1.0/255.0; bias = 0.0
    } else if vmin < -0.01 && vmax <= 1.5 { // looks like [-1,1]
        scale = 0.5; bias = 0.5
    } else { // assume [0,1]
        scale = 1.0; bias = 0.0
    }
    var pixels = [UInt8](repeating: 0, count: count * 4)
    for y in 0..<height {
        for x in 0..<width {
            let idx = y*width + x
            var r = arr[rBase + idx].floatValue * scale + bias
            var g = arr[gBase + idx].floatValue * scale + bias
            var b = arr[bBase + idx].floatValue * scale + bias
            r = min(max(r, 0), 1); g = min(max(g, 0), 1); b = min(max(b, 0), 1)
            let p = idx*4
            pixels[p+0] = UInt8(r * 255)
            pixels[p+1] = UInt8(g * 255)
            pixels[p+2] = UInt8(b * 255)
            pixels[p+3] = 255
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = ctx.makeImage() else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
}

// Simple content statistics to detect near-black outputs
func statsColor(_ arr: MLMultiArray) -> (std: Double, colorFrac: Double) {
    // arr is [1,3,H,W]
    let count = arr.count/3
    var sum: Double = 0, sum2: Double = 0
    var colorCnt = 0
    for i in 0..<count {
        let r = arr[i].floatValue
        let g = arr[count + i].floatValue
        let b = arr[2*count + i].floatValue
        let v = (Double(r) + Double(g) + Double(b)) / 3.0
        sum += v; sum2 += v*v
        if abs(r-g)+abs(r-b)+abs(g-b) > 0.02 { colorCnt += 1 }
    }
    let mean = sum / Double(max(count,1))
    let varv = max(0, sum2/Double(max(count,1)) - mean*mean)
    return (sqrt(varv), Double(colorCnt)/Double(max(count,1)))
}

func savePNG(_ img: NSImage, to url: URL) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

func main() throws {
    guard let args = parseArgs() else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: args.tempDir, withIntermediateDirectories: true)
    let framesDir = args.tempDir.appendingPathComponent("frames")
    let denoiseDir = args.tempDir.appendingPathComponent("denoised")
    let upscaledDir = args.tempDir.appendingPathComponent("upscaled")
    try? fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: denoiseDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: upscaledDir, withIntermediateDirectories: true)

    // 1) Extract frames as PNG
    try run(ffmpegPath(), ["-hide_banner","-y","-i", args.inputVideo, "-vsync","0", "-f","image2", "-pix_fmt","rgb24", framesDir.appendingPathComponent("%08d.png").path])

    // 2) Load models (compile .mlpackage first if needed)
    func loadModel(_ url: URL) throws -> MLModel {
        let cfg = MLModelConfiguration(); if #available(macOS 13.0, *) { cfg.computeUnits = .all }
        if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
            let compiled = try MLModel.compileModel(at: url)
            return try MLModel(contentsOf: compiled, configuration: cfg)
        }
        return try MLModel(contentsOf: url, configuration: cfg)
    }
    func findModel(_ name: String) -> URL? {
        let root = URL(fileURLWithPath: args.modelsDir)
        let tools = root.appendingPathComponent("Tools/\(name)")
        if fm.fileExists(atPath: tools.path) { return tools }
        let direct = root.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        return nil
    }
    guard let fastURL = findModel("FastDVDnet.mlpackage") else { throw NSError(domain:"CoreMLVSRCLI", code:1, userInfo:[NSLocalizedDescriptionKey:"FastDVDnet.mlpackage not found in models dir"]) }
    let rbvURL = findModel("RealBasicVSR_x2.mlpackage")
    let fastModel = try loadModel(fastURL)
    let rbvModel = try rbvURL.map(loadModel)

    // 3) Process frames streaming: FastDVDnet (5-frame window) -> RBV x2 -> save only upscaled
    let frameFiles = (try fm.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    let n = frameFiles.count
    func clamp(_ i: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, i)) }

    // 4) SR x2 (calibrate once on first denoised), streaming write to upscaled
    var rbvNormMode: Int = 0 // 0=[0..1], 1=[-1..1], 2=x255, 3=(x*255-127.5)/127.5
    var rbvBGRSwap: Bool = false

    func applyNorm(_ a: MLMultiArray, mode: Int, bgr: Bool) -> MLMultiArray? {
        // a is [1,3,H,W], already [0..1]
        let shape = a.shape.map{ $0.intValue }
        guard shape.count == 4, shape[0] == 1, shape[1] == 3 else { return nil }
        guard let out = try? MLMultiArray(shape: a.shape, dataType: .float32) else { return nil }
        let hw = shape[2]*shape[3]
        for i in 0..<hw {
            var r = a[i].floatValue
            var g = a[hw + i].floatValue
            var b = a[2*hw + i].floatValue
            if bgr { swap(&r, &b) }
            switch mode {
            case 1: // [-1..1]
                r = r*2 - 1; g = g*2 - 1; b = b*2 - 1
            case 2: // x255
                r = r*255; g = g*255; b = b*255
            case 3: // (x*255-127.5)/127.5
                r = (r*255 - 127.5)/127.5; g = (g*255 - 127.5)/127.5; b = (b*255 - 127.5)/127.5
            default: break // [0..1]
            }
            out[i] = NSNumber(value: r)
            out[hw + i] = NSNumber(value: g)
            out[2*hw + i] = NSNumber(value: b)
        }
        return out
    }

    // Helper to calibrate RBV on a sample array [1,3,H,W] in [0..1]
    func calibrateRBV(on baseArr: MLMultiArray) {
        guard let rbv = rbvModel else { return }
        // infer width/height
        let shape = baseArr.shape.map{ $0.intValue }
        let h = shape[2], w = shape[3]
        // Probe several norms/BGR and pick best by std+color fraction
        var best: (score: Double, mode: Int, bgr: Bool) = (-1, 0, false)
        for mode in 0...3 {
            for bgr in [false, true] {
                guard let aa = applyNorm(baseArr, mode: mode, bgr: bgr) else { continue }
                if let input = try? MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: aa)]),
                   let out = try? rbv.prediction(from: input), let y = out.featureValue(for: "var_867")?.multiArrayValue {
                    let st = statsColor(y)
                    let score = st.std + st.colorFrac
                    if score > best.score { best = (score, mode, bgr) }
                }
            }
        }
        if best.score >= 0 {
            rbvNormMode = best.mode; rbvBGRSwap = best.bgr
            fputs("[coreml-vsr-cli] RBV calibration: mode=\(rbvNormMode) bgr=\(rbvBGRSwap)\n", stderr)
        }
    }

    var rbvHealthy: Bool? = nil
    for i in 0..<n {
        // Build 5-frame input window
        let widx = [i-2,i-1,i,i+1,i+2].map { clamp($0, 0, n-1) }
        let reps: [NSBitmapImageRep] = widx.compactMap { loadImage(frameFiles[$0]) }
        guard reps.count == 5 else { continue }
        let h = reps[0].pixelsHigh, w = reps[0].pixelsWide
        let arr = try MLMultiArray(shape: [1,15,NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
        let dst = arr.dataPointer.bindMemory(to: Float32.self, capacity: 15*h*w)
        for (k,rep) in reps.enumerated() {
            guard let (a,_,_) = imageToArrayRGB(rep) else { continue }
            let src = a.dataPointer.bindMemory(to: Float32.self, capacity: 3*h*w)
            let count = h*w
            for c in 0..<3 {
                let dstBase = (k*3 + c) * count
                let srcBase = c * count
                (dst + dstBase).assign(from: src + srcBase, count: count)
            }
        }
        // FastDVDnet -> y [1,3,H,W]
        var y: MLMultiArray? = nil
        if let fm = fastModel as MLModel? {
            let input = try MLDictionaryFeatureProvider(dictionary: ["x_9": MLFeatureValue(multiArray: arr)])
            if let out = try? fm.prediction(from: input) { y = out.featureValue(for: "var_979")?.multiArrayValue }
        }
        // Fallback y: use center frame as-is
        if y == nil, let (a,_,_) = imageToArrayRGB(reps[2]) { y = a }
        guard let den = y else { continue }
        // Calibrate RBV on first usable frame
        if i == 0 { calibrateRBV(on: den) }
        // RBV upscale or CI fallback
        var saved = false
        if let rbv = rbvModel {
            let arrIn = applyNorm(den, mode: rbvNormMode, bgr: rbvBGRSwap) ?? den
            let inp = try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: arrIn)])
            if let out = try? rbv.prediction(from: inp), let up = out.featureValue(for: "var_867")?.multiArrayValue {
                if rbvHealthy == nil {
                    let st = statsColor(up)
                    rbvHealthy = (st.std >= 0.005 || st.colorFrac >= 0.01)
                }
                if rbvHealthy == true {
                    if let img = arrayToImage(up, width: w*2, height: h*2) {
                        savePNG(img, to: upscaledDir.appendingPathComponent(frameFiles[i].lastPathComponent))
                        saved = true
                    }
                }
            }
        }
        if !saved {
            // Bicubic fallback from denoised center
            if let img = arrayToImage(den, width: w, height: h) {
                let ci = CIImage(data: img.tiffRepresentation!)!; let scale = CGAffineTransform(scaleX: 2, y: 2)
                let out = ci.transformed(by: scale)
                let cg = gCIContext.createCGImage(out, from: out.extent)!
                let up = NSImage(cgImage: cg, size: NSSize(width: w*2, height: h*2))
                savePNG(up, to: upscaledDir.appendingPathComponent(frameFiles[i].lastPathComponent))
            }
        }
    }

    // 5) Reassemble video using source FPS and preserve original audio (if any)
    let outputURL = args.outputVideo != nil ? URL(fileURLWithPath: args.outputVideo!) : URL(fileURLWithPath: args.inputVideo).deletingPathExtension().appendingPathExtension("coreml_x2.mp4")
    let srcFPS = probeFPS(args.inputVideo)
    let fpsStr = String(format: "%.03f", srcFPS)
    let images = upscaledDir.appendingPathComponent("%08d.png").path
    try run(ffmpegPath(), [
        "-hide_banner", "-y",
        "-framerate", fpsStr,
        "-i", images,                // 0: video from frames
        "-i", args.inputVideo,       // 1: original, for audio
        "-map", "0:v:0",
        "-map", "1:a:0?",
        "-c:v", "libx264",
        "-crf", "18",
        "-preset", "veryfast",
        "-pix_fmt", "yuv420p",
        "-c:a", "copy",
        "-shortest",
        outputURL.path
    ])
    print("Saved: \(outputURL.path)")
}

do { try main() } catch { fputs("Error: \(error)\n", stderr) }
