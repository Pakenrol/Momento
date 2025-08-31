import Foundation
import CoreML
import AppKit

// RBVGuard: Try input layout/norm combos and detect black/gray output.

struct Combo { let axis: Int; let mode: Int; let bgr: Bool; let units: MLComputeUnits }

func ffmpegPath() -> String { ["/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg","/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/ffmpeg" }

func run(_ path: String, _ args: [String]) throws {
    let p = Process(); p.launchPath = path; p.arguments = args
    let e = Pipe(); p.standardError = e
    try p.run(); p.waitUntilExit()
    if p.terminationStatus != 0 {
        let s = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain:"RBVGuard", code:Int(p.terminationStatus), userInfo:[NSLocalizedDescriptionKey:"Command failed: \(path) \(args.joined(separator:" "))\n\n\(s)"])
    }
}

func extractFirstFrame(_ video: String, size: Int = 256) throws -> URL {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rbvguard_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let out = tmp.appendingPathComponent("0001.png")
    try run(ffmpegPath(), ["-hide_banner","-y","-v","error","-i", video, "-vf","scale=\(size):\(size):flags=lanczos", "-frames:v","1", out.path])
    return out
}

func loadImage(_ url: URL) -> NSImage? { NSImage(contentsOf: url) }

func imageToArrayNCHW(_ image: NSImage, size: Int = 256) -> MLMultiArray? {
    let target = NSSize(width: size, height: size)
    let scaled = NSImage(size: target)
    scaled.lockFocus(); image.draw(in: NSRect(origin: .zero, size: target)); scaled.unlockFocus()
    guard let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard let png = rep.representation(using: .png, properties: [:]), let ci = CIImage(data: png) else { return nil }
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)), let provider = cg.dataProvider, let raw = provider.data else { return nil }
    let ptr = CFDataGetBytePtr(raw)!
    let stride = w * 4
    let arr = try! MLMultiArray(shape: [1,3,NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
    for y in 0..<h { for x in 0..<w {
        let off = y*stride + x*4
        let r = Float(ptr[off+0]) / 255.0
        let g = Float(ptr[off+1]) / 255.0
        let b = Float(ptr[off+2]) / 255.0
        let base = y*w + x
        arr[base] = NSNumber(value: r)
        arr[h*w + base] = NSNumber(value: g)
        arr[2*h*w + base] = NSNumber(value: b)
    }}
    return arr
}

func toNHWC(_ src: MLMultiArray) -> MLMultiArray? {
    let shape = src.shape.map{ $0.intValue }
    guard shape.count == 4, shape[1] == 3 else { return nil }
    let h = shape[2], w = shape[3]
    let s = src.strides.map{ $0.intValue }
    guard let dst = try? MLMultiArray(shape: [1,NSNumber(value:h),NSNumber(value:w),3], dataType: .float32) else { return nil }
    let ds = dst.strides.map{ $0.intValue }
    for y in 0..<h { for x in 0..<w { for c in 0..<3 {
        let offSrc = 0*s[0] + c*s[1] + y*s[2] + x*s[3]
        let offDst = 0*ds[0] + y*ds[1] + x*ds[2] + c*ds[3]
        dst[offDst] = src[offSrc]
    }}}
    return dst
}

func applyMap(_ a: MLMultiArray, axis: Int, mode: Int, bgr: Bool) -> MLMultiArray? {
    var arr: MLMultiArray? = a
    if axis == 3 { arr = toNHWC(a) }
    guard var out = arr else { return nil }
    if bgr {
        let shp = out.shape.map{ $0.intValue }
        let s = out.strides.map{ $0.intValue }
        if let tmp = try? MLMultiArray(shape: out.shape, dataType: .float32) {
            let ts = tmp.strides.map{ $0.intValue }
            if shp[1] == 3 { // NCHW
                let h = shp[2], w = shp[3]
                for y in 0..<h { for x in 0..<w {
                    let r = out[0*s[1] + y*s[2] + x*s[3]]
                    let g = out[1*s[1] + y*s[2] + x*s[3]]
                    let b = out[2*s[1] + y*s[2] + x*s[3]]
                    tmp[2*ts[1] + y*ts[2] + x*ts[3]] = r
                    tmp[1*ts[1] + y*ts[2] + x*ts[3]] = g
                    tmp[0*ts[1] + y*ts[2] + x*ts[3]] = b
                }}
            } else if shp[3] == 3 { // NHWC
                let h = shp[1], w = shp[2]
                for y in 0..<h { for x in 0..<w {
                    let r = out[y*s[1] + x*s[2] + 0*s[3]]
                    let g = out[y*s[1] + x*s[2] + 1*s[3]]
                    let b = out[y*s[1] + x*s[2] + 2*s[3]]
                    tmp[y*ts[1] + x*ts[2] + 2*ts[3]] = r
                    tmp[y*ts[1] + x*ts[2] + 1*ts[3]] = g
                    tmp[y*ts[1] + x*ts[2] + 0*ts[3]] = b
                }}
            }
            out = tmp
        }
    }
    if let tmp = try? MLMultiArray(shape: out.shape, dataType: .float32) {
        let c = out.count
        switch mode {
        case 1: for i in 0..<c { tmp[i] = NSNumber(value: out[i].floatValue*2 - 1) }
        case 2: for i in 0..<c { tmp[i] = NSNumber(value: out[i].floatValue*255) }
        case 3: for i in 0..<c { tmp[i] = NSNumber(value: (out[i].floatValue*255 - 127.5)/127.5) }
        default: break
        }
        if mode != 0 { out = tmp }
    }
    return out
}

func statsColor(_ up: MLMultiArray) -> (std: Double, colorFrac: Double) {
    let shp = up.shape.map{ $0.intValue }
    guard shp.count == 4 else { return (0,0) }
    let (h,w,layoutNCHW) : (Int,Int,Bool) = (shp[1] == 3) ? (shp[2], shp[3], true) : (shp[1], shp[2], false)
    var sum: Double = 0, sum2: Double = 0
    var colorCnt = 0, total = h*w
    if layoutNCHW {
        let hw = h*w
        for i in 0..<hw {
            let r = up[i].floatValue; let g = up[hw + i].floatValue; let b = up[2*hw + i].floatValue
            let v = (Double(r) + Double(g) + Double(b))/3.0
            sum += v; sum2 += v*v
            if abs(r-g)+abs(r-b)+abs(g-b) > 0.02 { colorCnt += 1 }
        }
    } else {
        let s = up.strides.map{ $0.intValue }
        for y in 0..<h { for x in 0..<w {
            let r = up[y*s[1] + x*s[2] + 0*s[3]].floatValue
            let g = up[y*s[1] + x*s[2] + 1*s[3]].floatValue
            let b = up[y*s[1] + x*s[2] + 2*s[3]].floatValue
            let v = (Double(r)+Double(g)+Double(b))/3.0
            sum += v; sum2 += v*v
            if abs(r-g)+abs(r-b)+abs(g-b) > 0.02 { colorCnt += 1 }
        }}
    }
    let mean = sum / Double(total)
    let varv = max(0, sum2/Double(total) - mean*mean)
    return (sqrt(varv), Double(colorCnt)/Double(max(1,total)))
}

func findRBV(_ base: URL) -> URL? {
    let fm = FileManager.default
    let candidates = [
        base.appendingPathComponent("Tools/RealBasicVSR_x2.mlpackage"),
        base.appendingPathComponent("RealBasicVSR_x2.mlpackage")
    ]
    for c in candidates { if fm.fileExists(atPath: c.path) { return c } }
    return nil
}

func loadModel(at url: URL, units: MLComputeUnits) throws -> MLModel {
    let cfg = MLModelConfiguration(); if #available(macOS 13.0, *) { cfg.computeUnits = units }
    let compiled = try MLModel.compileModel(at: url)
    return try MLModel(contentsOf: compiled, configuration: cfg)
}

func main() throws {
    // Args: --image <png> | --video <mp4> [--save <out.png>]
    var imgPath: String? = nil
    var videoPath: String? = nil
    var outPath: String? = nil
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--image": imgPath = it.next()
        case "--video": videoPath = it.next()
        case "--save": outPath = it.next()
        case "-h","--help":
            print("Usage: RBVGuard (--image in.png | --video in.mp4) [--save out.png]")
            return
        default: break
        }
    }
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    guard let rbvURL = findRBV(base) else { throw NSError(domain:"RBVGuard", code:1, userInfo:[NSLocalizedDescriptionKey:"RealBasicVSR_x2.mlpackage not found in project root or Tools/"]) }
    let imageURL: URL
    if let p = imgPath { imageURL = URL(fileURLWithPath: p) }
    else if let v = videoPath { imageURL = try extractFirstFrame(v) }
    else { throw NSError(domain:"RBVGuard", code:2, userInfo:[NSLocalizedDescriptionKey:"Provide --image or --video"]) }
    guard let img = loadImage(imageURL), let src = imageToArrayNCHW(img) else { throw NSError(domain:"RBVGuard", code:3, userInfo:[NSLocalizedDescriptionKey:"Failed to load image"]) }

    // Build combos: prefer model-indicated axis if detectable
    var axisCandidates = [1,3]
    // Load once to inspect
    let modelGPU = try loadModel(at: rbvURL, units: .all)
    if let c = modelGPU.modelDescription.inputDescriptionsByName["x_1"]?.multiArrayConstraint {
        let shp = c.shape.map{ $0.intValue }
        if shp.count == 4, let ch = (0..<4).first(where: { shp[$0] == 3 }) { axisCandidates = [ch] + axisCandidates.filter{ $0 != ch } }
    }
    let modes = [0,1,2,3]
    let units: [MLComputeUnits] = [.all, .cpuOnly]
    var best: (Combo, Double, Double, MLMultiArray)? = nil // (combo, std, colorFrac, output)

    for u in units {
        let model = (u == .all) ? modelGPU : try loadModel(at: rbvURL, units: .cpuOnly)
        for ax in axisCandidates {
            for m in modes {
                for b in [false,true] {
                    guard let inp = applyMap(src, axis: ax, mode: m, bgr: b) else { continue }
                    let prov = try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: inp)])
                    guard let out = try? model.prediction(from: prov).featureValue(for: "var_867")?.multiArrayValue else { continue }
                    let (std, colorFrac) = statsColor(out)
                    // Accept if we have both variance and color
                    if colorFrac > 0.02 && std > 0.01 {
                        let combo = Combo(axis: ax, mode: m, bgr: b, units: u)
                        if best == nil || colorFrac > best!.2 { best = (combo, std, colorFrac, out) }
                    } else {
                        // Keep best seen for debugging anyway
                        if best == nil || colorFrac > best!.2 || std > best!.1 { best = (Combo(axis: ax, mode: m, bgr: b, units: u), std, colorFrac, out) }
                    }
                }
            }
        }
    }

    guard let res = best else { throw NSError(domain:"RBVGuard", code:4, userInfo:[NSLocalizedDescriptionKey:"No outputs produced"]) }
    let combo = res.0
    let pass = (res.1 > 0.01 && res.2 > 0.02)
    print(String(format: "PASS=%@ axis=%d mode=%d bgr=%@ units=%@ std=%.4f color=%.3f", pass ? "YES" : "NO", combo.axis, combo.mode, combo.bgr ? "YES":"NO", (combo.units == .all ? "GPU" : "CPU"), res.1, res.2))

    if let outPath = outPath {
        // Save PNG for visual check
        let shp = res.3.shape.map{ $0.intValue }
        let (h,w) : (Int,Int) = (shp[1] == 3) ? (shp[2], shp[3]) : (shp[1], shp[2])
        let isNCHW = shp[1] == 3
        var pixels = [UInt8](repeating: 0, count: h*w*4)
        if isNCHW {
            let hw = h*w
            for i in 0..<hw {
                let r = res.3[i].floatValue; let g = res.3[hw+i].floatValue; let b = res.3[2*hw+i].floatValue
                let p = i*4
                pixels[p] = UInt8(max(0,min(255, Int(r*255))))
                pixels[p+1] = UInt8(max(0,min(255, Int(g*255))))
                pixels[p+2] = UInt8(max(0,min(255, Int(b*255))))
                pixels[p+3] = 255
            }
        } else {
            let s = res.3.strides.map{ $0.intValue }
            for y in 0..<h { for x in 0..<w {
                let r = res.3[y*s[1] + x*s[2] + 0*s[3]].floatValue
                let g = res.3[y*s[1] + x*s[2] + 1*s[3]].floatValue
                let b = res.3[y*s[1] + x*s[2] + 2*s[3]].floatValue
                let p = (y*w+x)*4
                pixels[p] = UInt8(max(0,min(255, Int(r*255))))
                pixels[p+1] = UInt8(max(0,min(255, Int(g*255))))
                pixels[p+2] = UInt8(max(0,min(255, Int(b*255))))
                pixels[p+3] = 255
            }}
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = ctx.makeImage() {
            let img = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: outPath))
            }
        }
    }
}

do { try main() } catch { fputs("RBVGuard error: \(error)\n", stderr) }

