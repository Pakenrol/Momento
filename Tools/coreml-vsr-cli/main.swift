import Foundation
import CoreML
import CoreImage
import AppKit

// Simple CLI to run CoreML FastDVDnet denoising (5-frame window) then x2 SR.
// If RealBasicVSR_x2.mlmodelc is present and accepts single-frame input, use it.

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
    var rect = NSRect(origin: .zero, size: img.size)
    return img.representations.compactMap { $0 as? NSBitmapImageRep }.first ?? NSBitmapImageRep(data: img.tiffRepresentation!)
}

func imageToArrayRGB(_ rep: NSBitmapImageRep) -> (MLMultiArray, Int, Int)? {
    // Robust RGBA8 decode with correct row stride handling
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    guard let tiff = rep.representation(using: .png, properties: [:]) ?? rep.tiffRepresentation else { return nil }
    guard let srcImage = CIImage(data: tiff) else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CIContext()
    // Render into an RGBA8 buffer we control to guarantee bytesPerRow
    let outRect = CGRect(x: 0, y: 0, width: width, height: height)
    guard let cgRendered = ctx.createCGImage(srcImage, from: outRect, format: .RGBA8, colorSpace: colorSpace) else { return nil }
    let bytesPerRow = cgRendered.bytesPerRow
    guard let provider = cgRendered.dataProvider, let cfdata = provider.data else { return nil }
    let ptr = CFDataGetBytePtr(cfdata)!

    let arr = try! MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
    let countHW = height * width
    for y in 0..<height {
        let rowStart = y * bytesPerRow
        for x in 0..<width {
            let p = rowStart + x * 4
            // Buffer is RGBA8 (premultiplied), ignore alpha
            let r = Float(ptr[p + 0]) / 255.0
            let g = Float(ptr[p + 1]) / 255.0
            let b = Float(ptr[p + 2]) / 255.0
            let base = y * width + x
            arr[base] = NSNumber(value: r)
            arr[countHW + base] = NSNumber(value: g)
            arr[2*countHW + base] = NSNumber(value: b)
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

    // 3) Denoise via FastDVDnet (5-frame window), save center frame
    let frameFiles = (try fm.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    let n = frameFiles.count
    func clamp(_ i: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, i)) }

    for i in 0..<n {
        let widx = [i-2,i-1,i,i+1,i+2].map { clamp($0, 0, n-1) }
        let imgs: [NSBitmapImageRep] = widx.compactMap { loadImage(frameFiles[$0]) }
        guard imgs.count == 5 else { continue }
        // stack as [1,15,H,W]
        let h = imgs[0].pixelsHigh, w = imgs[0].pixelsWide
        let arr = try MLMultiArray(shape: [1,15,NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
        for (k,rep) in imgs.enumerated() {
            guard let (a,_,_) = imageToArrayRGB(rep) else { continue }
            let count = h*w
            // copy into arr channel block at k*3
            for c in 0..<3 {
                let dstBase = (k*3 + c) * count
                let srcBase = c*count
                for t in 0..<count { arr[dstBase + t] = a[srcBase + t] }
            }
        }
        if let fastModel = fastModel as MLModel? {
            let input = try MLDictionaryFeatureProvider(dictionary: ["x_9": MLFeatureValue(multiArray: arr)])
            if let out = try? fastModel.prediction(from: input), let y = out.featureValue(for: "var_979")?.multiArrayValue {
                if let img = arrayToImage(y, width: w, height: h) {
                    savePNG(img, to: denoiseDir.appendingPathComponent(frameFiles[i].lastPathComponent))
                }
                continue
            }
        }
        // fallback: copy center frame
        try? fm.copyItem(at: frameFiles[i], to: denoiseDir.appendingPathComponent(frameFiles[i].lastPathComponent))
    }

    // 4) SR x2: try RBV single-frame with simple calibration, else use Core Image upscale fallback
    var rbvNormMode: Int = 0 // 0=[0..1], 1=[-1..1], 2=x255, 3=(x*255-127.5)/127.5
    var rbvBGRSwap: Bool = false
    let upList = (try fm.contentsOfDirectory(at: denoiseDir, includingPropertiesForKeys: nil)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

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

    if let rbv = rbvModel, let first = upList.first, let rep = loadImage(first), let (baseArr, w, h) = imageToArrayRGB(rep) {
        // Probe several norms/BGR and pick best by std+color fraction
        var best: (score: Double, mode: Int, bgr: Bool) = (-1, 0, false)
        for mode in 0...3 {
            for bgr in [false, true] {
                guard let aa = applyNorm(baseArr, mode: mode, bgr: bgr) else { continue }
                let input = try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: aa)])
                if let out = try? rbv.prediction(from: input), let y = out.featureValue(for: "var_867")?.multiArrayValue {
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

    for url in upList {
        guard let rep = loadImage(url), let (srcArr, w, h) = imageToArrayRGB(rep) else { continue }
        var saved = false
        if let rbv = rbvModel {
            let arr = applyNorm(srcArr, mode: rbvNormMode, bgr: rbvBGRSwap) ?? srcArr
            let input = try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: arr)])
            if let out = try? rbv.prediction(from: input), let y = out.featureValue(for: "var_867")?.multiArrayValue {
                // Guard against near-black output
                let st = statsColor(y)
                if st.std < 0.005 && st.colorFrac < 0.01 {
                    // fall back to CI upscale
                } else if let img = arrayToImage(y, width: w*2, height: h*2) {
                    savePNG(img, to: upscaledDir.appendingPathComponent(url.lastPathComponent))
                    saved = true
                }
            }
        }
        if !saved {
            // CI upscale x2 fallback
            let ci = CIImage(contentsOf: url)!; let scale = CGAffineTransform(scaleX: 2, y: 2)
            let out = ci.transformed(by: scale)
            let ctx = CIContext(); let cg = ctx.createCGImage(out, from: out.extent)!
            let img = NSImage(cgImage: cg, size: NSSize(width: w*2, height: h*2))
            savePNG(img, to: upscaledDir.appendingPathComponent(url.lastPathComponent))
        }
    }

    // 5) Reassemble video using source FPS
    let outputURL = args.outputVideo != nil ? URL(fileURLWithPath: args.outputVideo!) : URL(fileURLWithPath: args.inputVideo).deletingPathExtension().appendingPathExtension("coreml_x2.mp4")
    try run(ffmpegPath(), ["-hide_banner","-y","-framerate","30","-i", upscaledDir.appendingPathComponent("%08d.png").path, "-c:v","libx264","-crf","18","-preset","veryfast","-pix_fmt","yuv420p", outputURL.path])
    print("Saved: \(outputURL.path)")
}

do { try main() } catch { fputs("Error: \(error)\n", stderr) }
