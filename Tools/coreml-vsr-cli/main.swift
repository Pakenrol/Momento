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
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    guard let data = rep.representation(using: .png, properties: [:]) ?? rep.tiffRepresentation else { return nil }
    guard let ci = CIImage(data: data) else { return nil }
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
    guard let provider = cg.dataProvider, let raw = provider.data else { return nil }
    let ptr = CFDataGetBytePtr(raw)!
    // Assume RGBA8
    let arr = try! MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
    let cStride = width * 4
    var idx = 0
    for y in 0..<height {
        let row = y * cStride
        for x in 0..<width {
            let offset = row + x * 4
            let r = Float(ptr[offset + 0]) / 255.0
            let g = Float(ptr[offset + 1]) / 255.0
            let b = Float(ptr[offset + 2]) / 255.0
            // NCHW: 1,3,H,W
            let base = y*width + x
            arr[base] = NSNumber(value: r)
            arr[height*width + base] = NSNumber(value: g)
            arr[2*height*width + base] = NSNumber(value: b)
            idx += 1
        }
    }
    return (arr, width, height)
}

func arrayToImage(_ arr: MLMultiArray, width: Int, height: Int) -> NSImage? {
    // Expect shape [1,3,H,W]
    let count = width * height
    let rBase = 0
    let gBase = count
    let bBase = count * 2
    var pixels = [UInt8](repeating: 0, count: count * 4)
    for y in 0..<height {
        for x in 0..<width {
            let idx = y*width + x
            let r = max(0, min(255, Int((arr[rBase + idx].floatValue) * 255.0)))
            let g = max(0, min(255, Int((arr[gBase + idx].floatValue) * 255.0)))
            let b = max(0, min(255, Int((arr[bBase + idx].floatValue) * 255.0)))
            let p = idx*4
            pixels[p+0] = UInt8(r)
            pixels[p+1] = UInt8(g)
            pixels[p+2] = UInt8(b)
            pixels[p+3] = 255
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = ctx.makeImage() else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
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

    // 4) SR x2: try RBV single-frame, else use Core Image upscale fallback
    for url in (try fm.contentsOfDirectory(at: denoiseDir, includingPropertiesForKeys: nil)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let rep = loadImage(url), let (arr, w, h) = imageToArrayRGB(rep) else { continue }
        var saved = false
        if let rbv = rbvModel {
            let input = try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: arr)])
            if let out = try? rbv.prediction(from: input), let y = out.featureValue(for: "var_867")?.multiArrayValue {
                if let img = arrayToImage(y, width: w*2, height: h*2) {
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
