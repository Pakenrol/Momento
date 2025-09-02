import SwiftUI
import Foundation
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
// MARK: - Project Memory/Init
/*
 Momento — AI video upscaler
 Current:
 - Core ML pipeline: FastDVDnet (denoise) + RealBasicVSR x2 (VSR)
 - Single simplified processing mode (Core ML)
*/
// App entry moved to AppEntry.swift
struct ContentView: View {
    @State private var selectedFile: URL?
    @State private var isProcessing = false
    @State private var progress: String = ""
    @State private var timeElapsed: String = ""
    @State private var dragOver = false
    @State private var startTime: Date?
    @State private var timer: Timer?
    @State private var currentStep: String = ""
    @State private var totalSteps: Int = 1
    @State private var currentStepIndex: Int = 0
    // Progress + ETA state
    @State private var progressValue: Double = 0.0 // 0.0 ... 1.0
    @State private var etaText: String = ""
    @State private var progressPollTimer: Timer?
    // Extraction context
    @State private var extractionTotalDuration: Double = 0.0
    // Frames processing context
    @State private var totalFramesCount: Int = 0
    @State private var processedFramesCount: Int = 0
    @State private var frameExtension: String = "png" // png or jpg
    // Cancellation support
    @State private var currentProcess: Process?
    @State private var workingTempDir: URL?
    // Log capture (tail of stdout/stderr)
    @State private var stdoutTail: [String] = []
    @State private var stderrTail: [String] = []
    // ETA smoothing for frame-based stages
    @State private var emaFrameTime: Double = 0.0
    @State private var lastRateSampleTime: Date?
    @State private var lastRateSampleFrames: Int = 0
    // Cooperative cancel for CoreML loops
    @State private var cancelRequested: Bool = false
    // Throttle UI progress updates
    @State private var lastUIUpdateTime: Date? = nil
    // Diagnostics
    @State private var enableRBVDiagnostics: Bool = false
    @State private var rbvDiagnosticsInfo: String = ""
    // FX-Upscale progress estimation
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Momento")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Text("FastDVDnet + RealBasicVSR | Professional AI Video Upscaler")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            // Drop zone
            VStack {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(dragOver ? .blue : .gray.opacity(0.5), style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(dragOver ? .blue.opacity(0.1) : .gray.opacity(0.03))
                    )
                    .frame(height: 140)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "video.badge.plus")
                                .font(.system(size: 50))
                                .foregroundColor(dragOver ? .blue : .secondary)
                            if let selectedFile = selectedFile {
                                Text(selectedFile.lastPathComponent)
                                    .font(.title3)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            } else {
                                VStack(spacing: 4) {
                                    Text("Drag & drop a video here")
                                        .font(.title3)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                    Text("Supported: MP4, MOV, AVI, MKV")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    )
                    .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                        handleDrop(providers: providers)
                    }
                // File buttons
                HStack {
                    Button("📁 Choose File") {
                        selectFile()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Spacer()
                    if selectedFile != nil {
                        Button("🗑️ Clear") {
                            selectedFile = nil
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            // Single mode: Core ML (no manual selection)
            // Start/Stop button
            HStack {
                Button(action: { isProcessing ? cancelProcessing() : startUpscaling() }) {
                    HStack(spacing: 8) {
                        Image(systemName: isProcessing ? "stop.circle" : "play.circle")
                            .font(.title2)
                        Text(isProcessing ? "Stop" : "🚀 Start Processing")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedFile == nil)
            }
            .padding(.horizontal)
            // Diagnostics disabled for streamlined UI
            // Processing progress
            if isProcessing || !progress.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if !progress.isEmpty {
                            Text(progress)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        // Overall progress (with ETA)
                        if isProcessing {
                            ProgressView(value: progressValue, total: 1.0)
                                .padding(.trailing, 8)
                            HStack(spacing: 12) {
                                Text(String(format: "%.0f%%", progressValue * 100))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if !etaText.isEmpty {
                                    Text("≈ " + etaText + " left")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            // Removed extra explanation text
                        }
                        if !currentStep.isEmpty {
                            Text("📍 \(currentStep)")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        if !timeElapsed.isEmpty {
                            Text("⏱️ \(timeElapsed)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if !rbvDiagnosticsInfo.isEmpty {
                            Text(rbvDiagnosticsInfo)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                        // Logs (tail)
                        if !stdoutTail.isEmpty {
                            Text(stdoutTail.suffix(6).joined(separator: "\n"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(6)
                                .multilineTextAlignment(.leading)
                        }
                        if !stderrTail.isEmpty {
                            Text(stderrTail.suffix(6).joined(separator: "\n"))
                                .font(.caption2)
                                .foregroundColor(.red.opacity(0.7))
                                .lineLimit(6)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
            // Footer info (fixed)
            VStack(spacing: 8) {
                Divider()
                // Always vertical layout for stability
                VStack(alignment: .leading, spacing: 2) {
                    Text("💡 Core ML: FastDVDnet + RealBasicVSR x2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text("🍎 Optimized for Apple Silicon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding(.top)
    }
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose a video to process"
        if panel.runModal() == .OK {
            selectedFile = panel.url
        }
    }
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            let allowedExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
            let fileExtension = url.pathExtension.lowercased()
            if allowedExtensions.contains(fileExtension) {
                DispatchQueue.main.async {
                    selectedFile = url
                }
            }
        }
        return true
    }
    private func startUpscaling() {
        guard let inputURL = selectedFile else { return }
        isProcessing = true
        startTime = Date()
        progress = "🔄 Initializing..."
        currentStepIndex = 1
        progressValue = 0
        etaText = ""
        processedFramesCount = 0
        totalFramesCount = 0
        resetLogTails()
        emaFrameTime = 0
        lastRateSampleTime = Date()
        lastRateSampleFrames = 0
        lastUIUpdateTime = nil
        cancelRequested = false
        // Core ML: always PNG for quality
        frameExtension = "png"
        // Extract + upscale + assemble (no RIFE)
        totalSteps = 3
        // Start timer for elapsed time updates
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            updateProgress()
        }
        // Read size and set x2 target (pipeline behavior)
        let originalSize = getVideoSize(url: inputURL)
        let targetWidth = originalSize.width * 2
        let targetHeight = originalSize.height * 2
        // Ensure CoreML models exist and start pipeline
        guard areCoreMLModelsAvailable() else {
            finishWithError("Core ML models FastDVDnet.mlpackage and RealBasicVSR_x2.mlpackage not found. Place them next to the app or in Resources.")
            return
        }
        processVSRCoreML(input: inputURL, width: targetWidth, height: targetHeight)
    }
    // MARK: - Paths helpers
    private func projectRoot() -> URL {
        // Try resolve relative to running bundle first, then workspace paths.
        let fm = FileManager.default
        // 1) App bundle Resources/bin (for packaged app)
        if let bundleURL = Bundle.main.resourceURL {
            let candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("Resources")
            if fm.fileExists(atPath: candidate.path) { return candidate.deletingLastPathComponent() }
        }
        // 2) Repo-local path (this workspace): Documents/coding/maccyscaler
        let repoNewLower = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/coding/maccyscaler")
        if fm.fileExists(atPath: repoNewLower.path) { return repoNewLower }
        // 3) New capitalized path
        let repoNewCap = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/Momento")
        if fm.fileExists(atPath: repoNewCap.path) { return repoNewCap }
        // 4) Backward compatibility: old lowercase/uppercase paths
        let repoOldLower = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/coding/vidyscaler")
        if fm.fileExists(atPath: repoOldLower.path) { return repoOldLower }
        let repoOldCap = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/Momento")
        if fm.fileExists(atPath: repoOldCap.path) { return repoOldCap }
        // 5) As a last resort, current working directory
        return URL(fileURLWithPath: fm.currentDirectoryPath)
    }
    private func projectBin() -> URL {
        // Prefer repo-local bin/
        let bin = projectRoot().appendingPathComponent("bin")
        return bin
    }
    private func findBinary(_ name: String) -> String? {
        let fm = FileManager.default
        // Common locations + project bin
        let candidates = [
            projectBin().appendingPathComponent(name).path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for p in candidates {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
    private func ffmpegPath() -> String {
        return findBinary("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg"
    }
    private func ffprobePath() -> String {
        return findBinary("ffprobe") ?? "/opt/homebrew/bin/ffprobe"
    }
    private func systemThreads() -> Int {
        return max(ProcessInfo.processInfo.activeProcessorCount, 1)
    }
    private func systemMemoryGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int((bytes + (1 << 29)) >> 30) // round to GB
    }
    private func tunedTileSize() -> String {
        // Conservative auto-tuning for Apple Silicon unified memory
        let gb = systemMemoryGB()
        if gb >= 64 { return "960" }
        if gb >= 32 { return "768" }
        if gb >= 16 { return "640" }
        return "512"
    }
    // NCNN path removed — Core ML only
    private func processVSRCoreML(input: URL, width: Int, height: Int) {
        currentStep = ""
        currentStepIndex = 1
        let outputURL = createOutputURL(from: input, suffix: "vsr", width: width, height: height)
        // New: prefer CLI pipeline for robustness/logging
        runCLIPipeline(input: input, output: outputURL)
    }
    // Удалены: processWaifu2x/processRealCUGAN (NCNN)
    // MARK: - Core ML VSR Pipeline (frames -> denoise -> VSR x2 -> assemble)
    private func areCoreMLModelsAvailable() -> Bool {
        return findMLPackage("FastDVDnet") != nil && findMLPackage("RealBasicVSR_x2") != nil
    }
    private func extractFramesAndProcessCoreML(input: URL, output: URL) {
        // Create temp folder
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Momento_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            workingTempDir = tempDir
            currentStep = "Extracting frames"
            // Extract frames (JPEG for fast, PNG for quality)
            let extractProcess = Process()
            extractProcess.launchPath = ffmpegPath()
            var args: [String] = ["-hide_banner", "-v", "error", "-progress", "pipe:1", "-i", input.path]
            if frameExtension == "jpg" {
                args += ["-q:v", "2", "\(tempDir.path)/%08d.jpg"]
            } else {
                args += ["-compression_level", "0", "\(tempDir.path)/%08d.png"]
            }
            extractProcess.arguments = args
            extractionTotalDuration = getVideoDuration(url: input)
            let outPipe = Pipe(); extractProcess.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("out_time_ms=") {
                        let v = line.replacingOccurrences(of: "out_time_ms=", with: "")
                        if let outMS = Double(v) {
                            let pct = min(max((outMS/1_000_000.0)/max(self.extractionTotalDuration, 0.0001), 0.0), 1.0)
                            DispatchQueue.main.async {
                                self.progressValue = pct
                                self.progress = "📤 Extracting frames: " + String(format: "%.0f%%", pct * 100)
                                self.updateETA(percent: pct)
                            }
                        }
                    }
                }
            }
            let errPipe = Pipe(); extractProcess.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { self.appendStderr(text) }
            }
            extractProcess.terminationHandler = { process in
                DispatchQueue.main.async {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus == 0 {
                        self.processFramesWithCoreMLVSRBatched(tempDir: tempDir, originalVideo: input, output: output)
                    } else {
                        self.finishWithError("Frame extraction failed")
                    }
                }
            }
            currentProcess = extractProcess
            try extractProcess.run()
        } catch {
            finishWithError("Core ML pipeline error: \(error.localizedDescription)")
        }
    }

    // MARK: - CLI Pipeline Wrapper
    private func runCLIPipeline(input: URL, output: URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Momento_CLI_\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {}
        workingTempDir = tempDir

        let fm = FileManager.default
        let projectRootDir = projectRoot()

        // Prefer embedded CLI binary inside packaged app; then dev prebuilt; then swift run; else fallback to Swift pipeline
        // Helper binary is placed under Resources to avoid extra Dock icon
        let packagedCLI = (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")).appendingPathComponent("coreml-vsr-cli")
        let cliSourceDir = projectRootDir.appendingPathComponent("Tools/coreml-vsr-cli")
        let devBuiltCLI = cliSourceDir.appendingPathComponent(".build/arm64-apple-macosx/release/coreml-vsr-cli")

        // Models directory: prefer app Resources for packaged app, else project root
        let modelsDir = Bundle.main.resourceURL ?? projectRootDir

        let p = Process()
        if fm.isExecutableFile(atPath: packagedCLI.path) {
            p.launchPath = packagedCLI.path
            p.arguments = ["--input", input.path, "--models", modelsDir.path, "--tmp", tempDir.path, "--output", output.path]
            p.currentDirectoryPath = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).path
        } else if fm.isExecutableFile(atPath: devBuiltCLI.path) {
            p.launchPath = devBuiltCLI.path
            p.arguments = ["--input", input.path, "--models", modelsDir.path, "--tmp", tempDir.path, "--output", output.path]
            p.currentDirectoryPath = projectRootDir.path
        } else if fm.fileExists(atPath: cliSourceDir.path) {
            p.launchPath = "/usr/bin/swift"
            p.arguments = ["run", "--package-path", cliSourceDir.path, "coreml-vsr-cli", "--input", input.path, "--models", modelsDir.path, "--tmp", tempDir.path, "--output", output.path]
            p.currentDirectoryPath = projectRootDir.path
        } else {
            appendStderr("[CLI] coreml-vsr-cli not found; falling back to built-in Core ML pipeline")
            extractFramesAndProcessCoreML(input: input, output: output)
            return
        }

        currentProcess = p
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.appendStdout(s) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.appendStderr(s) }
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                // Ensure progress visually completes
                self.progressValue = 1.0
                self.processedFramesCount = self.totalFramesCount
                self.finishProcessing(exitCode: proc.terminationStatus)
            }
        }
        do {
            try p.run()
            isProcessing = true
            // Don't print a dedicated Core ML stage label
            // Start polling tempDir and estimate progress by counting upscaled frames only
            let fpsGuess = max(1.0, self.getVideoFPS(url: input))
            let dur = max(0.001, self.getVideoDuration(url: input))
            var expected = max(1, Int((fpsGuess * dur).rounded()))
            self.totalFramesCount = expected
            self.processedFramesCount = 0
            self.currentStep = ""
            self.currentStepIndex = 0
            self.totalSteps = 0
            self.progressPollTimer?.invalidate()
            self.progressPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let fm = FileManager.default
                var nFrames = 0, nUpscaled = 0
                let framesDir = tempDir.appendingPathComponent("frames")
                let upscaleDir = tempDir.appendingPathComponent("upscaled")
                if let a = try? fm.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil) { nFrames = a.filter{ ["png","jpg","jpeg"].contains($0.pathExtension.lowercased()) }.count }
                if let a = try? fm.contentsOfDirectory(at: upscaleDir, includingPropertiesForKeys: nil) { nUpscaled = a.filter{ ["png","jpg","jpeg"].contains($0.pathExtension.lowercased()) }.count }
                // Dynamic expected converges to observed number of frames
                if nFrames > 0 { expected = nFrames }
                else if nUpscaled > 0 { expected = max(1, nUpscaled) }
                let fExp = Double(max(1, expected))
                let combined = min(1.0, Double(nUpscaled) / fExp)
                DispatchQueue.main.async {
                    self.progressValue = combined
                    self.processedFramesCount = nUpscaled
                    self.totalFramesCount = expected
                    self.progress = String(format: "📊 Frames: %d/%d", nUpscaled, expected)
                    self.updateETAFromFrames(processed: nUpscaled, total: expected)
                }
            }
        } catch {
            finishWithError("Failed to launch CLI: \(error.localizedDescription)")
        }
    }
    private func processFramesWithCoreMLVSR(tempDir: URL, originalVideo: URL, output: URL) {
        currentStep = "FastDVDnet + RealBasicVSR (Core ML)"
        let outputFramesDir = tempDir.appendingPathComponent("upscaled")
        do { try FileManager.default.createDirectory(at: outputFramesDir, withIntermediateDirectories: true) } catch {}
        
        // Load CoreML models
        // Locate model packages and provide detailed errors
        let fastURL = findMLPackage("FastDVDnet")
        let rbvURL = findMLPackage("RealBasicVSR_x2")
        if fastURL == nil || rbvURL == nil {
            let msg = "CoreML models not found:\nFastDVDnet: \(fastURL?.path ?? "—")\nRealBasicVSR_x2: \(rbvURL?.path ?? "—")"
            finishWithError(msg)
            return
        }
        guard let fastDVDModel = loadCoreMLModel(name: "FastDVDnet.mlpackage") else {
            finishWithError("Failed to load FastDVDnet: \(fastURL!.path)")
            return
        }
        guard let realBasicVSRModel = loadCoreMLModel(name: "RealBasicVSR_x2.mlpackage") else {
            finishWithError("Failed to load RealBasicVSR_x2: \(rbvURL!.path)")
            return
        }
        
        // Collect frames list
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == frameExtension })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            finishWithError("Failed to list frames for Core ML")
            return
        }
        
        totalFramesCount = files.count
        processedFramesCount = 0
        progressValue = 0
        
        DispatchQueue.global(qos: .userInitiated).async(execute: {
            if self.cancelRequested { return }
            // Stage 1: Denoise with FastDVDnet (5-frame window)
            var denoisedFrames: [MLMultiArray] = []
            
            for i in 0..<files.count {
                if self.cancelRequested { return }
                autoreleasepool {
                    // Create 5-frame window for FastDVDnet
                    var frameWindow: [NSImage] = []
                    for j in -2...2 {
                        let frameIndex = max(0, min(files.count - 1, i + j))
                        if let image = NSImage(contentsOf: files[frameIndex]) {
                            frameWindow.append(image)
                        }
                    }
                    
                    guard frameWindow.count == 5 else {
                        if self.cancelRequested { return }
                        DispatchQueue.main.async { self.finishWithError("Failed to build 5-frame window") }
                        return
                    }
                    
                    // Build input tensor [1, 15, 256, 256]
                    if let inputArray = self.create5FrameInput(frames: frameWindow) {
                        do {
                            let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["x_9": MLFeatureValue(multiArray: inputArray)])
                            let output = try fastDVDModel.prediction(from: inputFeatures)
                            
                            if let denoisedArray = output.featureValue(for: "var_979")?.multiArrayValue {
                                denoisedFrames.append(denoisedArray)
                            } else {
                                if let arr = self.nsImageToMLMultiArray(frameWindow[2]) { denoisedFrames.append(arr) }
                            }
                        } catch {
                            if let arr = self.nsImageToMLMultiArray(frameWindow[2]) { denoisedFrames.append(arr) }
                        }
                    } else {
                        if let arr = self.nsImageToMLMultiArray(frameWindow[2]) { denoisedFrames.append(arr) }
                    }
                    
                    DispatchQueue.main.async {
                        self.processedFramesCount = i + 1
                        let frac = Double(self.processedFramesCount) / Double(max(self.totalFramesCount, 1))
                        self.progressValue = 0.5 * frac
                        self.progress = "🧹 FastDVDnet denoise: " + String(format: "%.0f%% (\(self.processedFramesCount)/\(self.totalFramesCount))", self.progressValue * 100)
                        self.updateETAFromFrames(processed: self.processedFramesCount, total: self.totalFramesCount * 2)
                    }
                }
            }
            
            // Stage 2: Upscale x2 with RealBasicVSR
            for (idx, denoisedArray) in denoisedFrames.enumerated() {
                if self.cancelRequested { return }
                autoreleasepool {
                    do {
                        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: denoisedArray)])
                        let output = try realBasicVSRModel.prediction(from: inputFeatures)
                            
                            if let upscaledArray = output.featureValue(for: "var_867")?.multiArrayValue,
                               let upscaledImage = self.multiArrayToNSImage(upscaledArray) {
                                let outputURL = outputFramesDir.appendingPathComponent(files[idx].lastPathComponent)
                                self.saveNSImage(upscaledImage, to: outputURL)
                            } else {
                            if let center = NSImage(contentsOf: files[idx]) {
                                let resizedImage = self.resizeImage(center, scale: 2.0)
                                let outputURL = outputFramesDir.appendingPathComponent(files[idx].lastPathComponent)
                                self.saveNSImage(resizedImage, to: outputURL)
                            }
                        }
                    } catch {
                        if let center = NSImage(contentsOf: files[idx]) {
                            let resizedImage = self.resizeImage(center, scale: 2.0)
                            let outputURL = outputFramesDir.appendingPathComponent(files[idx].lastPathComponent)
                            self.saveNSImage(resizedImage, to: outputURL)
                        }
                    }
                    
                    DispatchQueue.main.async {
                        let done = idx + 1
                        let frac = Double(done) / Double(max(self.totalFramesCount, 1))
                        self.progressValue = 0.5 + 0.5 * frac
                        self.progress = "📈 RealBasicVSR x2: " + String(format: "%.0f%% (\(done)/\(self.totalFramesCount))", self.progressValue * 100)
                        let totalProcessed = self.totalFramesCount + done
                        self.updateETAFromFrames(processed: totalProcessed, total: self.totalFramesCount * 2)
                    }
                }
            }
            
            if self.cancelRequested { return }
            DispatchQueue.main.async {
                if self.cancelRequested { return }
                self.reassembleVideo(framesDir: outputFramesDir, originalVideo: originalVideo, output: output, tempDir: tempDir)
            }
        })
    }
    // Оптимизированный батчевый пайплайн: кэш, батчи, кооперативная отмена
    private func processFramesWithCoreMLVSRBatched(tempDir: URL, originalVideo: URL, output: URL) {
        currentStep = "FastDVDnet + RealBasicVSR (CoreML)"
        let outputFramesDir = tempDir.appendingPathComponent("upscaled")
        do { try FileManager.default.createDirectory(at: outputFramesDir, withIntermediateDirectories: true) } catch {}
        guard let fastDVDModel = loadCoreMLModel(name: "FastDVDnet.mlpackage"),
              var realBasicVSRModel = loadCoreMLModel(name: "RealBasicVSR_x2.mlpackage") else {
            finishWithError("Failed to load Core ML models")
            return
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == frameExtension })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            finishWithError("Failed to list frames for Core ML")
            return
        }
        totalFramesCount = files.count
        processedFramesCount = 0
        progressValue = 0
        let workItem = DispatchWorkItem {
            if self.cancelRequested { return }
            var tensorCache: [Int: MLMultiArray] = [:]
            func tensorForFrame(_ idx: Int) -> MLMultiArray? {
                if let t = tensorCache[idx] { return t }
                guard let img = NSImage(contentsOf: files[idx]), let t = self.nsImageToMLMultiArray(img) else { return nil }
                tensorCache[idx] = t
                return t
            }
            // Two strict stages without interleaving
            // Update steps (1/3): Denoise
            DispatchQueue.main.async {
                self.totalSteps = 3
                // Step 2/3: processing (denoise + upscale)
                self.currentStepIndex = 2
                self.currentStep = "Denoise (FastDVDnet)"
            }
            let denoisedDir = tempDir.appendingPathComponent("var_979")
            try? FileManager.default.createDirectory(at: denoisedDir, withIntermediateDirectories: true)
            let opts = MLPredictionOptions(); if #available(macOS 12.0, *) { opts.usesCPUOnly = false }
            let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
            let conc = max(2, min(cores, 8))
            // Buffer of denoised tensors to preserve dynamic range
            var denoisedArrays = [Int: MLMultiArray]()
            let denoisedLock = NSLock()
            // Stage 1: FastDVDnet for all frames (parallel, no interleaving)
            let g1 = DispatchGroup(); let s1 = DispatchSemaphore(value: conc)
            var done1 = 0
            for idx in 0..<files.count {
                if self.cancelRequested { break }
                s1.wait(); g1.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { s1.signal(); g1.leave() }
                    if self.cancelRequested { return }
                    var tensors: [MLMultiArray] = []
                    for j in -2...2 { let fi = max(0, min(files.count - 1, idx + j)); if let t = tensorForFrame(fi) { tensors.append(t) } }
                    guard tensors.count == 5, let window = self.create5FrameInputFromTensors(tensors) else { return }
                    if let out = try? fastDVDModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x_9": MLFeatureValue(multiArray: window)]), options: opts),
                       let arr = out.featureValue(for: "var_979")?.multiArrayValue {
                        denoisedLock.lock(); denoisedArrays[idx] = arr; denoisedLock.unlock()
                    }
                    done1 += 1
                    if done1 % 3 == 0 || done1 == self.totalFramesCount {
                        let local = done1
                        DispatchQueue.main.async {
                            if self.cancelRequested { return }
                            let frac = Double(local) / Double(max(self.totalFramesCount, 1))
                            let overall = 0.5 * frac
                            if overall > self.progressValue { self.progressValue = overall }
                            self.progress = String(format: "🧹 FastDVDnet denoise: %.0f%% (%d/%d)", frac * 100, local, self.totalFramesCount)
                            self.updateETAFromFrames(processed: local, total: self.totalFramesCount * 2)
                        }
                    }
                }
            }
            g1.wait()
            // Move to step 2/3: Upscale
            DispatchQueue.main.async {
                // Step remains 2/3 throughout the processing stage
                self.currentStepIndex = 2
                self.currentStep = "Upscale (RealBasicVSR x2)"
            }
            // Stage 2: RealBasicVSR for all frames (parallel)
            // Calibrate on the first example and select computeUnits (GPU/CPU) if GPU returns constants
            var calibArr: MLMultiArray? = nil
            denoisedLock.lock(); calibArr = denoisedArrays[0]; denoisedLock.unlock()
            // 0) Try saved config
            var unitsUsed = "GPU"
            var rbvCfg: RBVInputConfig
            var rbvDisabled = false
            if let saved = self.loadSavedRBVConfig(), let a = calibArr {
                let savedCfg = saved.0; let savedUnits = saved.1
                if let testInS = self.applyLayoutAndNorm(a, axis: savedCfg.channelAxis, mode: savedCfg.mode, bgrSwap: savedCfg.bgrSwap) {
                    let modelS = (savedUnits == "CPU") ? (self.loadCoreMLModel(name: "RealBasicVSR_x2.mlpackage", units: .cpuOnly) ?? realBasicVSRModel) : realBasicVSRModel
                    if let outS = try? modelS.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: testInS)])), let upS = outS.featureValue(for: "var_867")?.multiArrayValue {
                        let scS = self.statsColor(upS)
                        if scS.std > 0.01 && scS.colorFrac > 0.02 {
                            rbvCfg = savedCfg; unitsUsed = savedUnits
                        } else {
                            rbvCfg = self.calibrateRBVConfig(example: a, rbv: realBasicVSRModel)
                        }
                    } else {
                        rbvCfg = self.calibrateRBVConfig(example: a, rbv: realBasicVSRModel)
                    }
                } else {
                    rbvCfg = self.calibrateRBVConfig(example: a, rbv: realBasicVSRModel)
                }
            } else {
                rbvCfg = calibArr != nil ? self.calibrateRBVConfig(example: calibArr!, rbv: realBasicVSRModel) : RBVInputConfig(channelAxis: (self.modelChannelAxis(realBasicVSRModel, input: "x_1") ?? 1), mode: 0, bgrSwap: false)
            }
            // 1) Verify on GPU and maybe fallback to CPU
            if let a = calibArr, let testIn = self.applyLayoutAndNorm(a, axis: rbvCfg.channelAxis, mode: rbvCfg.mode, bgrSwap: rbvCfg.bgrSwap),
                let testOut = try? realBasicVSRModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: testIn)])),
                let up = testOut.featureValue(for: "var_867")?.multiArrayValue {
                let scGPU = self.statsColor(up)
                if scGPU.std < 0.005 || scGPU.colorFrac < 0.01, let rbvCPU = self.loadCoreMLModel(name: "RealBasicVSR_x2.mlpackage", units: .cpuOnly) {
                    // Try CPU mode and recalibration
                    let cfgCPU = self.calibrateRBVConfig(example: a, rbv: rbvCPU)
                    if let testIn2 = self.applyLayoutAndNorm(a, axis: cfgCPU.channelAxis, mode: cfgCPU.mode, bgrSwap: cfgCPU.bgrSwap),
                       let out2 = try? rbvCPU.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: testIn2)])),
                       let up2 = out2.featureValue(for: "var_867")?.multiArrayValue {
                        let scCPU = self.statsColor(up2)
                        if scCPU.std > scGPU.std || scCPU.colorFrac > scGPU.colorFrac {
                            realBasicVSRModel = rbvCPU; rbvCfg = cfgCPU; unitsUsed = "CPU"
                            self.appendStdout("[DBG] RBV GPU returned poor output; switched to CPU + recalibration")
                        } else if scGPU.std < 0.005 && scGPU.colorFrac < 0.01 && scCPU.std < 0.005 && scCPU.colorFrac < 0.01 {
                            // Both ineffective — disable RBV and use bicubic
                            rbvDisabled = true
                            self.appendStdout("[DBG] RBV disabled (both backends ineffective), using bicubic")
                        }
                    }
                } else if scGPU.std < 0.005 && scGPU.colorFrac < 0.01 {
                    rbvDisabled = true
                    self.appendStdout("[DBG] RBV disabled (GPU ineffective), using bicubic")
                }
            }
            DispatchQueue.main.async {
                let modeDesc: String = {
                    switch rbvCfg.mode { case 1: return "[-1..1]"; case 2: return "x255"; case 3: return "(x*255-127.5)/127.5"; default: return "[0..1]" }
                }()
                self.rbvDiagnosticsInfo = rbvDisabled ? "RBV disabled (fallback bicubic)" : "RBV cfg: axis=\(rbvCfg.channelAxis), norm=\(modeDesc), BGR=\(rbvCfg.bgrSwap), units=\(unitsUsed)"
            }
            // Persist config
            if !rbvDisabled { self.saveRBVConfig(rbvCfg, units: unitsUsed) }
            let g2 = DispatchGroup(); let s2 = DispatchSemaphore(value: conc)
            var done2 = 0
            for idx in 0..<files.count {
                if self.cancelRequested { break }
                s2.wait(); g2.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { s2.signal(); g2.leave() }
                    if self.cancelRequested { return }
                    // Take tensor from denoise buffer and apply selected transform
                    denoisedLock.lock(); let inputArr = denoisedArrays[idx]; denoisedLock.unlock()
                    if rbvDisabled {
                        // Полный fallback: bicubic-up denоised, иначе от исходного кадра
                        let url = outputFramesDir.appendingPathComponent(files[idx].lastPathComponent)
                        if let a = inputArr, let baseImg = self.multiArrayToNSImage(a) {
                            self.saveNSImage(self.resizeImage(baseImg, scale: 2.0), to: url)
                        } else if let srcImg = NSImage(contentsOf: files[idx]) {
                            self.saveNSImage(self.resizeImage(srcImg, scale: 2.0), to: url)
                        }
                    } else if let a = inputArr, let input = self.applyLayoutAndNorm(a, axis: rbvCfg.channelAxis, mode: rbvCfg.mode, bgrSwap: rbvCfg.bgrSwap),
                        let out = try? realBasicVSRModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: input)]), options: opts),
                        let up = out.featureValue(for: "var_867")?.multiArrayValue {
                        let url = outputFramesDir.appendingPathComponent(files[idx].lastPathComponent)
                        let sc = self.statsColor(up)
                        let useDirect = self.isImageLike(up) && sc.std > 0.01 && sc.colorFrac > 0.02
                        if useDirect {
                            if let img = self.multiArrayToNSImage(up) { self.saveNSImage(img, to: url) }
                            else {
                                // Fallback to base-up if conversion failed
                                if let baseImg = self.multiArrayToNSImage(a) { self.saveNSImage(self.resizeImage(baseImg, scale: 2.0), to: url) }
                                else if let srcImg = NSImage(contentsOf: files[idx]) { self.saveNSImage(self.resizeImage(srcImg, scale: 2.0), to: url) }
                            }
                        } else {
                            // Treat RBV output as residual; compose over bicubic-up of denoised center
                            if let baseImg = self.multiArrayToNSImage(a) {
                                let w = a.shape[3].intValue * 2
                                let h = a.shape[2].intValue * 2
                                let baseUp = self.resizeImage(baseImg, scale: 2.0)
                                if sc.std < 0.005 || sc.colorFrac < 0.01 {
                                    // Совсем бесполезный выход — берём чистый bicubic
                                    self.saveNSImage(baseUp, to: url)
                                } else if let baseArr = self.nsImageToMLMultiArrayScaled(baseUp, width: w, height: h),
                                   let comp = try? MLMultiArray(shape: up.shape, dataType: .float32) {
                                    let cnt = up.count
                                    // Residual scale depends on input normalization
                                    let scale: Float
                                    switch rbvCfg.mode {
                                    case 2: scale = 1.0/255.0
                                    case 3: scale = 1.0 // already normalized-ish residual
                                    case 1: scale = 0.5 // map [-1..1] residual to ~[-0.5..0.5]
                                    default: scale = 1.0
                                    }
                                    for i in 0..<cnt {
                                        let v = baseArr[i].floatValue + up[i].floatValue * scale
                                        comp[i] = NSNumber(value: max(0, min(1, v)))
                                    }
                                    if let img = self.multiArrayToNSImage(comp) { self.saveNSImage(img, to: url) }
                                    else { self.saveNSImage(baseUp, to: url) }
                                } else { self.saveNSImage(baseUp, to: url) }
                            } else if let srcImg = NSImage(contentsOf: files[idx]) {
                                self.saveNSImage(self.resizeImage(srcImg, scale: 2.0), to: url)
                            }
                        }
                        // Diagnostics disabled
                    }
                    done2 += 1
                    if done2 % 3 == 0 || done2 == self.totalFramesCount {
                        let local = done2
                        DispatchQueue.main.async {
                            if self.cancelRequested { return }
                            let frac = Double(local) / Double(max(self.totalFramesCount, 1))
                            let overall = 0.5 + 0.5 * frac
                            if overall > self.progressValue { self.progressValue = overall }
                            self.progress = String(format: "📈 RealBasicVSR x2: %.0f%% (%d/%d)", frac * 100, local, self.totalFramesCount)
                            let totalProcessed = self.totalFramesCount + local
                            self.updateETAFromFrames(processed: totalProcessed, total: self.totalFramesCount * 2)
                        }
                    }
                }
            }
            g2.wait()
            if self.cancelRequested { return }
            DispatchQueue.main.async {
                if self.cancelRequested { return }
                // Diagnostics disabled
                self.reassembleVideo(framesDir: outputFramesDir, originalVideo: originalVideo, output: output, tempDir: tempDir)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
    private func writeImage(_ image: CIImage, to url: URL, context: CIContext, ext: String) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw NSError(domain: "Momento", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, (ext == "png" ? kUTTypePNG : kUTTypeJPEG) as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if ext == "jpg" { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "Momento", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to write image"])
        }
    }
    // Removed: extractFramesAndProcess + NCNN upscalers (RealESRGAN/RealCUGAN/Waifu2x)
    private func reassembleVideo(framesDir: URL, originalVideo: URL, output: URL, tempDir: URL) {
        currentStep = "Assembling final video"
        currentStepIndex = 3
        
        // Diagnostics for assembly
        let frameFiles = (try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == frameExtension }) ?? []
        appendStdout("[DBG] Frames to assemble: \(frameFiles.count) in \(framesDir.path)")
        if frameFiles.count > 0 { appendStdout("[DBG] First: \(frameFiles.prefix(3).map{ $0.lastPathComponent }.joined(separator: ", "))") }
        // Get original video FPS
        let fps = getVideoFPS(url: originalVideo)
        let process = Process()
        process.launchPath = ffmpegPath()
        var args: [String] = [
            "-hide_banner", "-v", "error",
            "-progress", "pipe:1",
            "-threads", "0",
            "-vsync", "0",
            "-framerate", String(format: "%.03f", fps),
            "-i", "\(framesDir.path)/%08d.\(self.frameExtension)",
            "-i", originalVideo.path,
        ]
        // Scale to target resolution if needed
        let targetName = output.deletingPathExtension().lastPathComponent
        if let xRange = targetName.range(of: #"_(\d+)x(\d+)$"#, options: .regularExpression) {
            let dims = String(targetName[xRange]).dropFirst()
            let parts = dims.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                let filt = "lanczos"
                args += ["-vf", "scale=\(w):\(h):flags=\(filt)"]
            }
        }
        // Prefer libx264 for robustness; avoids rare VideoToolbox black output
        args += [
            "-c:v", "libx264",
            "-crf", "18",
            "-preset", "veryfast",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            "-c:a", "copy",
            "-map", "0:v:0",
            "-map", "1:a:0?",
            "-y",
            output.path
        ]
        process.arguments = args
        // Build progress from ffmpeg out_time_ms vs duration
        let duration = max(getVideoDuration(url: originalVideo), 0.0001)
        let outPipe = Pipe()
        process.standardOutput = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n")
            for line in lines {
                if line.hasPrefix("out_time_ms=") {
                    let v = line.replacingOccurrences(of: "out_time_ms=", with: "")
                    if let outMS = Double(v) {
                        let pct = min(max((outMS / 1_000_000.0) / duration, 0.0), 1.0)
                        DispatchQueue.main.async {
                            self.progressValue = pct
                            self.progress = "📦 Muxing video: " + String(format: "%.0f%%", pct * 100)
                            self.updateETA(percent: pct)
                        }
                    }
                }
            }
            DispatchQueue.main.async { self.appendStdout(text) }
        }
        let errPipe = Pipe(); process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.appendStderr(text) }
        }
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Cleanup temp files
                try? FileManager.default.removeItem(at: tempDir)
                self.workingTempDir = nil
                self.finishProcessing(exitCode: process.terminationStatus)
            }
        }
        do {
            currentProcess = process
            try process.run()
        } catch {
            finishWithError("Video assembly failed: \(error.localizedDescription)")
        }
    }
    private func finishProcessing(exitCode: Int32) {
        timer?.invalidate()
        timer = nil
        progressPollTimer?.invalidate()
        progressPollTimer = nil
        isProcessing = false
        currentStep = ""
        currentProcess = nil
        workingTempDir = nil
        emaFrameTime = 0
        lastRateSampleTime = nil
        lastRateSampleFrames = 0
        etaText = ""
        if exitCode == 0 {
            progress = "✅ Processing completed successfully!"
            showSuccessAlert()
        } else {
            progress = "❌ Processing failed (code: \(exitCode))"
            showErrorAlert("Process finished with an error")
        }
    }
    private func finishWithError(_ message: String) {
        timer?.invalidate()
        timer = nil
        progressPollTimer?.invalidate()
        progressPollTimer = nil
        isProcessing = false
        currentStep = ""
        progress = "❌ \(message)"
        showErrorAlert(message)
    }
    private func getVideoSize(url: URL) -> (width: Int, height: Int) {
        let process = Process()
        process.launchPath = ffprobePath()
        process.arguments = [
            "-v", "quiet",
            "-print_format", "csv",
            "-show_entries", "stream=width,height",
            "-select_streams", "v:0",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let components = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
                if components.count >= 2,
                   let width = Int(components[0]),
                   let height = Int(components[1]) {
                    return (width, height)
                }
            }
        } catch {
            print("Failed to get size: \(error)")
        }
        return (640, 480)
    }
    private func getVideoFPS(url: URL) -> Double {
        let process = Process()
        process.launchPath = ffprobePath()
        process.arguments = [
            "-v", "quiet",
            "-print_format", "csv",
            "-show_entries", "stream=r_frame_rate",
            "-select_streams", "v:0",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let fpsString = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let slashRange = fpsString.range(of: "/") {
                    let numerator = String(fpsString[..<slashRange.lowerBound])
                    let denominator = String(fpsString[slashRange.upperBound...])
                    if let num = Double(numerator), let den = Double(denominator), den != 0 {
                        return num / den
                    }
                }
            }
        } catch {
            print("Failed to get FPS: \(error)")
        }
        return 30.0
    }
    private func createOutputURL(from inputURL: URL, suffix: String, width: Int, height: Int) -> URL {
        let directory = inputURL.deletingLastPathComponent()
        let filename = inputURL.deletingPathExtension().lastPathComponent
        let newFilename = "\(filename)_\(suffix)_x2.mp4"
        return directory.appendingPathComponent(newFilename)
    }
    private func updateProgress() {
        guard let startTime = startTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            timeElapsed = "\(minutes)m \(seconds)s"
        } else {
            timeElapsed = "\(seconds)s"
        }
    }
    private func updateETAFromFrames(processed: Int, total: Int) {
        guard processed > 0, total > 0 else { etaText = ""; return }
        let now = Date()
        if let lastT = lastRateSampleTime {
            let dt = now.timeIntervalSince(lastT)
            let df = processed - lastRateSampleFrames
            if df > 0 && dt > 0.1 {
                let inst = dt / Double(df) // sec/frame
                if emaFrameTime == 0 { emaFrameTime = inst } else { emaFrameTime = 0.3 * inst + 0.7 * emaFrameTime }
                let remaining = max(total - processed, 0)
                // avoid noisy ETA in the beginning — wait for ~20 frames
                if processed < 20 {
                    etaText = "estimating..."
                } else {
                    let rem = emaFrameTime * Double(remaining)
                    let m = Int(rem) / 60
                    let s = Int(rem) % 60
                    etaText = m > 0 ? String(format: "%dm %02ds", m, s) : String(format: "%ds", s)
                }
            }
        }
        lastRateSampleTime = now
        lastRateSampleFrames = processed
    }
    private func updateETA(percent: Double) {
        guard let start = startTime, percent > 0.01 else {
            etaText = ""
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed * (1.0 - percent) / percent
        // Hide unrealistic huge values (> 2h)
        if remaining > 7200 {
            etaText = ""
            return
        }
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        etaText = m > 0 ? String(format: "%dm %02ds", m, s) : String(format: "%ds", s)
    }
    private func getVideoDuration(url: URL) -> Double {
        let process = Process()
        process.launchPath = ffprobePath()
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "csv=p=0",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0
            }
        } catch {
            print("Failed to get duration: \(error)")
        }
        return 0.0
    }
    private func cancelProcessing() {
        cancelRequested = true
        // Terminate current external process and cleanup
        currentProcess?.terminate()
        currentProcess = nil
        timer?.invalidate(); timer = nil
        progressPollTimer?.invalidate(); progressPollTimer = nil
        isProcessing = false
        currentStep = ""
        progressValue = 0
        etaText = ""
        emaFrameTime = 0
        lastRateSampleTime = nil
        lastRateSampleFrames = 0
        if let tmp = workingTempDir {
            try? FileManager.default.removeItem(at: tmp)
            workingTempDir = nil
        }
        progress = "⏹ Operation cancelled"
    }
    private func showSuccessAlert() {
        let alert = NSAlert()
        alert.messageText = "🎉 Processing complete!"
        alert.informativeText = "The video has been processed and saved next to the original file."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "❌ Error"
        let details = getErrorSnippet()
        if details.isEmpty {
            alert.informativeText = message
        } else {
            alert.informativeText = message + "\n\nDetails:\n" + details
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
// MARK: - CoreML Helper Functions
extension ContentView {
    struct RBVInputConfig { let channelAxis: Int; let mode: Int; let bgrSwap: Bool }
    private func statsColor(_ up: MLMultiArray) -> (std: Double, colorFrac: Double) {
        let shape = up.shape.map { $0.intValue }
        guard shape.count == 4 else { return (0,0) }
        let isNCHW = shape[1] == 3
        let h = isNCHW ? shape[2] : shape[1]
        let w = isNCHW ? shape[3] : shape[2]
        var sum: Double = 0, sum2: Double = 0
        var colorCnt = 0
        let total = max(1, h*w)
        if isNCHW {
            let hw = h*w
            for i in 0..<hw {
                let r = up[i].floatValue
                let g = up[hw+i].floatValue
                let b = up[2*hw+i].floatValue
                let v = (Double(r)+Double(g)+Double(b))/3.0
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
        return (sqrt(varv), Double(colorCnt)/Double(total))
    }
    private func computeStd(_ arr: MLMultiArray) -> Double {
        let n = arr.count
        if n == 0 { return 0 }
        var sum: Double = 0, sum2: Double = 0
        for i in 0..<n {
            let v = Double(arr[i].floatValue)
            sum += v; sum2 += v*v
        }
        let mean = sum / Double(n)
        let varv = max(0, sum2/Double(n) - mean*mean)
        return sqrt(varv)
    }
    // mode: 0=[0..1], 1=[-1..1] (x*2-1), 2=x*255, 3=(x*255-127.5)/127.5
    private func applyLayoutAndNorm(_ arr: MLMultiArray, axis: Int, mode: Int, bgrSwap: Bool) -> MLMultiArray? {
        var a: MLMultiArray? = arr
        // layout
        if axis == 3, arr.shape.count == 4, arr.shape[1].intValue == 3 { a = toNHWC(arr) }
        if axis == 1, arr.shape.count == 4, arr.shape[3].intValue == 3 { a = toNCHW(arr) }
        guard var out = a else { return nil }
        // optional BGR swap
        if bgrSwap, out.shape.count == 4 {
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
            case 1: // [-1..1]
                for i in 0..<c { tmp[i] = NSNumber(value: out[i].floatValue * 2.0 - 1.0) }
                out = tmp
            case 2: // x255
                for i in 0..<c { tmp[i] = NSNumber(value: out[i].floatValue * 255.0) }
                out = tmp
            case 3: // (x*255-127.5)/127.5
                for i in 0..<c { tmp[i] = NSNumber(value: (out[i].floatValue * 255.0 - 127.5) / 127.5) }
                out = tmp
            default:
                break
            }
        }
        return out
    }
    private func isImageLike(_ arr: MLMultiArray) -> Bool {
        let shape = arr.shape.map{ $0.intValue }
        guard shape.count == 4 else { return false }
        // quick min/max sample
        let strides = arr.strides.map{ $0.intValue }
        let chanAxis = ([1,2,3].first{ shape[$0] == 3 }) ?? 1
        let spatial = [1,2,3].filter{ $0 != chanAxis }
        let h = shape[spatial[0]], w = shape[spatial[1]]
        let ys = stride(from: 0, to: max(h,1), by: max(h/8,1))
        let xs = stride(from: 0, to: max(w,1), by: max(w/8,1))
        var vmin = Float.greatestFiniteMagnitude, vmax: Float = -Float.greatestFiniteMagnitude
        var colorCnt = 0, total = 0
        for y in ys { for x in xs {
            let r = arr[0*strides[chanAxis] + y*strides[spatial[0]] + x*strides[spatial[1]]].floatValue
            let g = arr[1*strides[chanAxis] + y*strides[spatial[0]] + x*strides[spatial[1]]].floatValue
            let b = arr[2*strides[chanAxis] + y*strides[spatial[0]] + x*strides[spatial[1]]].floatValue
            let v = max(0,min(1,(r+g+b)/3))
            if r<g || r<b || g<b || g<r || b<r || b<g { if abs(r-g)+abs(r-b)+abs(g-b) > 0.02 { colorCnt += 1 } }
            if v < vmin { vmin = v }; if v > vmax { vmax = v }
            total += 1
        }}
        let colorFrac = total > 0 ? Double(colorCnt)/Double(total) : 0
        // consider image-like if within [0..1] roughly and some color present
        return (vmin > -0.05 && vmax < 1.05 && colorFrac > 0.02)
    }
    // Ensure AppKit drawing happens on main thread
    private func onMain<T>(_ block: () -> T) -> T {
        if Thread.isMainThread { return block() }
        var result: T! = nil
        DispatchQueue.main.sync { result = block() }
        return result
    }
    private func calibrateRBVConfig(example: MLMultiArray, rbv: MLModel) -> RBVInputConfig {
        let detected = modelChannelAxis(rbv, input: "x_1")
        let axisCandidates: [Int] = detected != nil ? [detected!] : [1,3]
        var bestCfg = RBVInputConfig(channelAxis: axisCandidates.first ?? 1, mode: 0, bgrSwap: false)
        var bestStd: Double = -1
        var bestColor: Double = -1
        let modes = [0,1,2,3]
        for ax in axisCandidates {
            for m in modes {
                for bgr in [false, true] {
                    if let adapted = applyLayoutAndNorm(example, axis: ax, mode: m, bgrSwap: bgr),
                       let out = try? rbv.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: adapted)])),
                       let up = out.featureValue(for: "var_867")?.multiArrayValue {
                        let sc = statsColor(up)
                        // Prefer combos that pass thresholds, then by colorFrac, then std
                        let passes = (sc.std > 0.01 && sc.colorFrac > 0.02)
                        let bestPasses = (bestStd > 0.01 && bestColor > 0.02)
                        if (passes && !bestPasses) ||
                           (passes && bestPasses && (sc.colorFrac > bestColor || (abs(sc.colorFrac - bestColor) < 1e-6 && sc.std > bestStd))) ||
                           (!passes && !bestPasses && (sc.colorFrac > bestColor || (abs(sc.colorFrac - bestColor) < 1e-6 && sc.std > bestStd))) {
                            bestStd = sc.std; bestColor = sc.colorFrac; bestCfg = RBVInputConfig(channelAxis: ax, mode: m, bgrSwap: bgr)
                        }
                    }
                }
            }
        }
        return bestCfg
    }
    // Determine channel axis (returns 1 for NCHW or 3 for NHWC when 3-channel)
    private func modelChannelAxis(_ model: MLModel, input name: String) -> Int? {
        let desc = model.modelDescription
        if let fd = desc.inputDescriptionsByName[name], let c = fd.multiArrayConstraint {
            let shp = c.shape
            // shape contains NSNumbers or -1 wildcards
            var axis: Int? = nil
            for i in 0..<shp.count {
                let v = shp[i].intValue
                if v == 3 { axis = i; break }
            }
            return axis
        }
        return nil
    }
    // Convert NHWC -> NCHW [1, H, W, 3] to [1, 3, H, W]
    private func toNCHW(_ src: MLMultiArray) -> MLMultiArray? {
        let shape = src.shape.map { $0.intValue }
        guard shape.count == 4 else { return nil }
        let strides = src.strides.map { $0.intValue }
        guard let cax = ([1,2,3].first { shape[$0] == 3 }) else { return nil }
        let spatial = [1,2,3].filter { $0 != cax }
        guard spatial.count == 2 else { return nil }
        let h = shape[spatial[0]]
        let w = shape[spatial[1]]
        guard let dst = try? MLMultiArray(shape: [1,3,NSNumber(value:h),NSNumber(value:w)], dataType: .float32) else { return nil }
        let dstStrides = dst.strides.map { $0.intValue }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let offSrcC = c*strides[cax]
                    let offSrcY = y*strides[spatial[0]]
                    let offSrcX = x*strides[spatial[1]]
                    let offSrc = offSrcC + offSrcY + offSrcX
                    let offDst = c*dstStrides[1] + y*dstStrides[2] + x*dstStrides[3]
                    dst[offDst] = src[offSrc]
                }
            }
        }
        return dst
    }
    // Convert NCHW -> NHWC [1,3,H,W] to [1,H,W,3]
    private func toNHWC(_ src: MLMultiArray) -> MLMultiArray? {
        let shape = src.shape.map { $0.intValue }
        guard shape.count == 4, shape[1] == 3 else { return nil }
        let h = shape[2], w = shape[3]
        let s = src.strides.map { $0.intValue }
        guard let dst = try? MLMultiArray(shape: [1,NSNumber(value:h),NSNumber(value:w),3], dataType: .float32) else { return nil }
        let ds = dst.strides.map { $0.intValue }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let offSrc = 0*s[0] + c*s[1] + y*s[2] + x*s[3]
                    let offDst = 0*ds[0] + y*ds[1] + x*ds[2] + c*ds[3]
                    dst[offDst] = src[offSrc]
                }
            }
        }
        return dst
    }
    // Locate .mlpackage in SwiftPM bundle, app resources, sub-bundles, or workspace
    private func findMLPackage(_ baseName: String) -> URL? {
        let fm = FileManager.default
        print("[DEBUG] Looking for model: \(baseName)")
        // 1) Check workspace fallbacks first (development mode)
        let candidates: [URL] = [projectRoot(), URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/Momento"), URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/MaccyScaler")]
        print("[DEBUG] Candidates: \(candidates.map { $0.path })")
        for base in candidates {
            let pTools = base.appendingPathComponent("Tools/\(baseName).mlpackage")
            print("[DEBUG] Check Tools: \(pTools.path) - exists: \(fm.fileExists(atPath: pTools.path))")
            if fm.fileExists(atPath: pTools.path) { 
                print("[DEBUG] Found in Tools: \(pTools.path)")
                return pTools 
            }
            let pRoot = base.appendingPathComponent("\(baseName).mlpackage")
            print("[DEBUG] Check Root: \(pRoot.path) - exists: \(fm.fileExists(atPath: pRoot.path))")
            if fm.fileExists(atPath: pRoot.path) { 
                print("[DEBUG] Found in Root: \(pRoot.path)")
                return pRoot 
            }
        }
        // 2) App main bundle resources
        if let url = Bundle.main.url(forResource: baseName, withExtension: "mlpackage"), fm.fileExists(atPath: url.path) {
            return url
        }
        // 3) Embedded SwiftPM bundle copied into Resources
        if let resRoot = Bundle.main.resourceURL {
            // Try new bundle name first, then legacy
            let spmBundleURLNew = resRoot.appendingPathComponent("Momento_Momento.bundle")
            let spmBundleURLOld = resRoot.appendingPathComponent("MaccyScaler_MaccyScaler.bundle")
            if let b = Bundle(url: spmBundleURLNew),
               let url = b.url(forResource: baseName, withExtension: "mlpackage"),
               fm.fileExists(atPath: url.path) {
                return url
            }
            if let b = Bundle(url: spmBundleURLOld), let url = b.url(forResource: baseName, withExtension: "mlpackage"), fm.fileExists(atPath: url.path) {
                return url
            }
            // 4) Last resort: walk Resources recursively for *.mlpackage
            if let en = fm.enumerator(at: resRoot, includingPropertiesForKeys: nil) {
                for case let url as URL in en {
                    if url.pathExtension == "mlpackage" && url.deletingPathExtension().lastPathComponent == baseName {
                        return url
                    }
                }
            }
        }
        // Workspace fallbacks were checked above
        print("[DEBUG] Model \(baseName) not found!")
        return nil
    }
    private func loadSavedRBVConfig() -> (RBVInputConfig, String)? {
        let d = UserDefaults.standard
        let key = "RBVConfig"
        guard let dict = d.dictionary(forKey: key) as? [String: Any] else { return nil }
        let axis = dict["axis"] as? Int ?? 1
        let mode = dict["mode"] as? Int ?? 0
        let bgr = dict["bgr"] as? Bool ?? false
        let units = dict["units"] as? String ?? "GPU"
        return (RBVInputConfig(channelAxis: axis, mode: mode, bgrSwap: bgr), units)
    }
    private func saveRBVConfig(_ cfg: RBVInputConfig, units: String) {
        let d = UserDefaults.standard
        let dict: [String: Any] = ["axis": cfg.channelAxis, "mode": cfg.mode, "bgr": cfg.bgrSwap, "units": units]
        d.set(dict, forKey: "RBVConfig")
    }
    private func loadCoreMLModel(name: String) -> MLModel? {
        let base = (name as NSString).deletingPathExtension
        guard let url = findMLPackage(base) else { return nil }
        do {
            let config = MLModelConfiguration()
            if #available(macOS 13.0, *) { config.computeUnits = .all }
            let loadURL: URL
            let ext = url.pathExtension.lowercased()
            if ext == "mlpackage" || ext == "mlmodel" {
                let compiled = try MLModel.compileModel(at: url)
                loadURL = compiled
            } else {
                loadURL = url // assume compiled .mlmodelc
            }
            return try MLModel(contentsOf: loadURL, configuration: config)
        } catch {
            let desc = (error as NSError).localizedDescription
            print("Failed to load model \(name) at: \(url.path) — \(desc)")
            return nil
        }
    }
    // Overload with explicit compute units
    private func loadCoreMLModel(name: String, units: MLComputeUnits) -> MLModel? {
        let base = (name as NSString).deletingPathExtension
        guard let url = findMLPackage(base) else { return nil }
        do {
            let config = MLModelConfiguration()
            if #available(macOS 13.0, *) { config.computeUnits = units } else { config.computeUnits = .cpuOnly }
            let loadURL: URL
            let ext = url.pathExtension.lowercased()
            if ext == "mlpackage" || ext == "mlmodel" {
                let compiled = try MLModel.compileModel(at: url)
                loadURL = compiled
            } else {
                loadURL = url
            }
            return try MLModel(contentsOf: loadURL, configuration: config)
        } catch {
            let desc = (error as NSError).localizedDescription
            print("Failed to load model \(name) (\(units)) at: \(url.path) — \(desc)")
            return nil
        }
    }
    
    private func create5FrameInput(frames: [NSImage]) -> MLMultiArray? {
        guard frames.count == 5 else { return nil }
        
        // Создаем массив [1, 15, 256, 256] - 5 кадров × 3 канала
        guard let inputArray = try? MLMultiArray(shape: [1, 15, 256, 256], dataType: .float32) else {
            return nil
        }
        
        for (frameIdx, frame) in frames.enumerated() {
            // Resize кадра до 256x256
            let resizedFrame = resizeImageTo256(frame)
            
            // Извлекаем RGB пиксели
            if let pixelData = getRGBPixels(from: resizedFrame) {
                let frameOffset = frameIdx * 3 * 256 * 256
                
                // Копируем каналы R, G, B
                for c in 0..<3 {
                    let channelOffset = c * 256 * 256
                    let targetOffset = frameOffset + channelOffset
                    
                    for i in 0..<(256 * 256) {
                        let pixelIdx = i * 3 + c
                        let normalizedValue = Float(pixelData[pixelIdx]) / 255.0
                        inputArray[targetOffset + i] = NSNumber(value: normalizedValue)
                    }
                }
            }
        }
        
        return inputArray
    }
    // Сборка окна из 5 уже подготовленных тензоров [1,3,256,256] в [1,15,256,256]
    private func create5FrameInputFromTensors(_ tensors: [MLMultiArray]) -> MLMultiArray? {
        guard tensors.count == 5 else { return nil }
        guard let inputArray = try? MLMultiArray(shape: [1, 15, 256, 256], dataType: .float32) else { return nil }
        let hw = 256 * 256
        for (f, t) in tensors.enumerated() {
            for c in 0..<3 {
                let dstBase = f * 3 * hw + c * hw
                for i in 0..<hw {
                    inputArray[dstBase + i] = t[c * hw + i]
                }
            }
        }
        return inputArray
    }
    
    private func nsImageToMLMultiArray(_ image: NSImage) -> MLMultiArray? {
        let resized = resizeImageTo256(image)
        guard let pixelData = getRGBPixels(from: resized),
              let array = try? MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32) else {
            return nil
        }
        
        // Заполняем массив в формате NCHW
        for c in 0..<3 {
            for i in 0..<(256 * 256) {
                let pixelIdx = i * 3 + c
                let normalizedValue = Float(pixelData[pixelIdx]) / 255.0
                array[c * 256 * 256 + i] = NSNumber(value: normalizedValue)
            }
        }
        
        return array
    }
    
    private func multiArrayToNSImage(_ array: MLMultiArray) -> NSImage? {
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 4, shape[0] == 1 else { return nil }
        let strides = array.strides.map { $0.intValue }
        // Определяем ось каналов (там где размер = 3 и не batch)
        guard let chanAxis = ([1,2,3].first { shape[$0] == 3 }) else { return nil }
        let spatialAxes = [1,2,3].filter { $0 != chanAxis }
        let hAxis = spatialAxes[0]
        let wAxis = spatialAxes[1]
        let height = shape[hAxis]
        let width = shape[wAxis]
        // Быстрая выборка для оценки диапазона значений
        var vmin: Float = Float.greatestFiniteMagnitude
        var vmax: Float = -Float.greatestFiniteMagnitude
        let ys = stride(from: 0, to: max(height,1), by: max(height/8,1))
        let xs = stride(from: 0, to: max(width,1), by: max(width/8,1))
        for y in ys { for x in xs { for c in 0..<3 {
            let off = 0*strides[0] + (c*strides[chanAxis]) + (y*strides[hAxis]) + (x*strides[wAxis])
            let v = array[off].floatValue
            if v < vmin { vmin = v }; if v > vmax { vmax = v }
        }}}
        var scale: Float = 1.0, bias: Float = 0.0
        if vmax > 2.0 { scale = 1.0/255.0; bias = 0.0 }
        else if vmin < -0.01 && vmax <= 1.5 { scale = 0.5; bias = 0.5 }
        else { scale = 1.0; bias = 0.0 }
        var pixelData = [UInt8](repeating: 0, count: width * height * 4) // RGBA
        // Конвертируем универсально по strides
        for y in 0..<height {
            for x in 0..<width {
                let pixelIdx = (y * width + x) * 4
                let rOff = 0*strides[0] + (0*strides[chanAxis]) + (y*strides[hAxis]) + (x*strides[wAxis])
                let gOff = 0*strides[0] + (1*strides[chanAxis]) + (y*strides[hAxis]) + (x*strides[wAxis])
                let bOff = 0*strides[0] + (2*strides[chanAxis]) + (y*strides[hAxis]) + (x*strides[wAxis])
                var r = array[rOff].floatValue * scale + bias
                var g = array[gOff].floatValue * scale + bias
                var b = array[bOff].floatValue * scale + bias
                if r < 0 { r = 0 } else if r > 1 { r = 1 }
                if g < 0 { g = 0 } else if g > 1 { g = 1 }
                if b < 0 { b = 0 } else if b > 1 { b = 1 }
                pixelData[pixelIdx + 0] = UInt8(r * 255)
                pixelData[pixelIdx + 1] = UInt8(g * 255)
                pixelData[pixelIdx + 2] = UInt8(b * 255)
                pixelData[pixelIdx + 3] = 255
            }
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixelData, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = context.makeImage() else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
    
    private func resizeImageTo256(_ image: NSImage) -> NSImage {
        return onMain {
            let newSize = NSSize(width: 256, height: 256)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize))
            resized.unlockFocus()
            return resized
        }
    }
    
    private func resizeImage(_ image: NSImage, scale: CGFloat) -> NSImage {
        return onMain {
            let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize))
            resized.unlockFocus()
            return resized
        }
    }
    
    private func nsImageToMLMultiArrayScaled(_ image: NSImage, width: Int, height: Int) -> MLMultiArray? {
        return onMain {
            let target = NSSize(width: width, height: height)
            let scaled = NSImage(size: target)
            scaled.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: target))
            scaled.unlockFocus()
            guard let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            let w = rep.pixelsWide, h = rep.pixelsHigh
            guard let arr = try? MLMultiArray(shape: [1,3,NSNumber(value: h), NSNumber(value: w)], dataType: .float32) else { return nil }
            guard let data = rep.representation(using: .png, properties: [:]), let ci = CIImage(data: data) else { return nil }
            let ctx = CIContext()
            guard let cg = ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)), let provider = cg.dataProvider, let raw = provider.data else { return nil }
            let ptr = CFDataGetBytePtr(raw)!
            let stride = w * 4
            for y in 0..<h {
                for x in 0..<w {
                    let off = y*stride + x*4
                    let r = Float(ptr[off+0]) / 255.0
                    let g = Float(ptr[off+1]) / 255.0
                    let b = Float(ptr[off+2]) / 255.0
                    let base = y*w + x
                    arr[base] = NSNumber(value: r)
                    arr[h*w + base] = NSNumber(value: g)
                    arr[2*h*w + base] = NSNumber(value: b)
                }
            }
            return arr
        }
    }
    
    private func getRGBPixels(from image: NSImage) -> [UInt8]? {
        return onMain {
            // Render NSImage into 256x256 RGBA8 context and extract RGB bytes efficiently
            let target = CGSize(width: 256, height: 256)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8, bytesPerRow: Int(target.width) * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: NSRect(origin: .zero, size: NSSize(width: target.width, height: target.height)))
            NSGraphicsContext.restoreGraphicsState()
            guard let buffer = ctx.data else { return nil }
            let count = Int(target.width * target.height)
            var rgb = [UInt8](repeating: 0, count: count * 3)
            let ptr = buffer.bindMemory(to: UInt8.self, capacity: count * 4)
            var di = 0
            for i in 0..<count {
                let si = i * 4
                rgb[di] = ptr[si]
                rgb[di+1] = ptr[si+1]
                rgb[di+2] = ptr[si+2]
                di += 3
            }
            return rgb
        }
    }
    
    private func saveNSImage(_ image: NSImage, to url: URL) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return
        }
        
        let ext = url.pathExtension.lowercased()
        let imageType: NSBitmapImageRep.FileType = (ext == "png") ? .png : .jpeg
        
        guard let data = bitmap.representation(using: imageType, properties: [:]) else {
            return
        }
        
        try? data.write(to: url)
    }
}

// MARK: - Log helpers
extension ContentView {
    private func resetLogTails() {
        stdoutTail.removeAll(); stderrTail.removeAll()
    }
    private func appendStdout(_ text: String) {
        appendToTail(&stdoutTail, text: text)
    }
    private func appendStderr(_ text: String) {
        appendToTail(&stderrTail, text: text)
    }
    private func appendToTail(_ tail: inout [String], text: String, maxLines: Int = 40) {
        let parts = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for p in parts {
            let s = String(p)
            if !s.isEmpty {
                tail.append(s)
                if tail.count > maxLines {
                    tail.removeFirst(tail.count - maxLines)
                }
            }
        }
    }
    private func getErrorSnippet() -> String {
        if !stderrTail.isEmpty { return stderrTail.suffix(12).joined(separator: "\n") }
        if !stdoutTail.isEmpty { return stdoutTail.suffix(8).joined(separator: "\n") }
        return ""
    }
}
