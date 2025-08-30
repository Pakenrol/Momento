import SwiftUI
import Foundation
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
// MARK: - Project Memory/Init
/*
 MaccyScaler - Продвинутый видеоапскейлер для реставрации старых видео
 АРХИТЕКТУРА:
 - Waifu2x: Быстрый режим (в 4.7 раз быстрее Real-ESRGAN)
 - RealCUGAN: Качественный режим (лучшее соотношение качество/скорость)
 ЦЕЛЬ: Максимальная скорость и качество для апскейлинга старых видео 90х-2000х
 ПРИНЦИП: Два режима - "Быстро" и "Качество", оптимизированы под Apple Silicon
 ИНСТРУМЕНТЫ:
 - bin/waifu2x-ncnn-vulkan (быстрый)
 - bin/realcugan-ncnn-vulkan (качественный)
 РЕЖИМЫ:
 1. Быстро: Waifu2x (0.12с на кадр)
 2. Качество: RealCUGAN (0.28с на кадр)
*/
@main
struct MaccyScalerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 750, maxWidth: 950, minHeight: 650, maxHeight: 850)
        }
        .windowResizability(.contentSize)
    }
}
// Убрали выбор алгоритма — всё прячется под режимами Fast/Quality
enum ProcessingMode: Int, CaseIterable {
    case fast = 0
    case quality = 1
    var name: String {
        switch self {
        case .fast: return "Быстро"
        case .quality: return "Качество"
        }
    }
}
struct ContentView: View {
    @State private var selectedFile: URL?
    @State private var isProcessing = false
    @State private var progress: String = ""
    @State private var timeElapsed: String = ""
    // Только два режима
    @State private var selectedMode = ProcessingMode.fast
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
    // FX-Upscale progress estimation
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            // Заголовок
            VStack(alignment: .leading, spacing: 8) {
                Text("MaccyScaler")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Text("Профессиональная реставрация и апскейлинг старых видео")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            // Drop зона
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
                                    Text("Перетащите видео сюда")
                                        .font(.title3)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                    Text("Поддерживаются: MP4, MOV, AVI, MKV")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    )
                    .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                        handleDrop(providers: providers)
                    }
                // Кнопки файла
                HStack {
                    Button("📁 Выбрать файл") {
                        selectFile()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Spacer()
                    if selectedFile != nil {
                        Button("🗑️ Очистить") {
                            selectedFile = nil
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            // Убран выбор алгоритма — оставили только Режим
            // Режим обработки
            VStack(alignment: .leading, spacing: 8) {
                Text("⚙️ Режим:")
                    .font(.headline)
                    .fontWeight(.semibold)
                Picker("", selection: $selectedMode) {
                    ForEach(ProcessingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260, alignment: .leading)
            }
            .padding(.horizontal)
            // Кнопка запуска / остановки
            HStack {
                Button(action: { isProcessing ? cancelProcessing() : startUpscaling() }) {
                    HStack(spacing: 8) {
                        Image(systemName: isProcessing ? "stop.circle" : "play.circle")
                            .font(.title2)
                        Text(isProcessing ? "Остановить" : "🚀 Начать обработку")
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
            // Прогресс обработки
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
                        // Visual progress bar with percentage and ETA
                        if isProcessing {
                            ProgressView(value: progressValue, total: 1.0)
                                .padding(.trailing, 8)
                            HStack(spacing: 12) {
                                Text(String(format: "%.0f%%", progressValue * 100))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if !etaText.isEmpty {
                                    Text("≈ " + etaText + " осталось")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        if !currentStep.isEmpty {
                            Text("📍 \(currentStep) (\(currentStepIndex)/\(totalSteps))")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        if !timeElapsed.isEmpty {
                            Text("⏱️ \(timeElapsed)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
            // Информационная панель (фиксированная)
            VStack(spacing: 8) {
                Divider()
                // Всегда вертикальное расположение для стабильности
                VStack(alignment: .leading, spacing: 6) {
                    Text("💡 Быстро: Waifu2x, Качество: RealCUGAN")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.8)
                    Text("🍎 Оптимизировано для Apple Silicon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        panel.title = "Выберите видеофайл для обработки"
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
        progress = "🔄 Инициализация обработки..."
        currentStepIndex = 1
        progressValue = 0
        etaText = ""
        processedFramesCount = 0
        totalFramesCount = 0
        resetLogTails()
        emaFrameTime = 0
        lastRateSampleTime = Date()
        lastRateSampleFrames = 0
        // Настройка формата кадров под режим
        frameExtension = (selectedMode == .fast) ? "jpg" : "png"
        // Определяем количество шагов по режиму
        totalSteps = 3 // Извлечение + апскейл + сборка (без RIFE для упрощения)
        // Запускаем таймер для обновления времени
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            updateProgress()
        }
        // Получаем размеры и делаем x2 апскейлинг (соответствует алгоритмам)
        let originalSize = getVideoSize(url: inputURL)
        let targetWidth = originalSize.width * 2
        let targetHeight = originalSize.height * 2
        // Запускаем пайплайн VSR (Core ML при наличии моделей, иначе fallback)
        runVSRPipeline(input: inputURL, width: targetWidth, height: targetHeight)
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
        let repoNewCap = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/MaccyScaler")
        if fm.fileExists(atPath: repoNewCap.path) { return repoNewCap }
        // 4) Backward compatibility: old lowercase/uppercase paths
        let repoOldLower = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/coding/vidyscaler")
        if fm.fileExists(atPath: repoOldLower.path) { return repoOldLower }
        let repoOldCap = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/MaccyScaler")
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
    private func tunedJobs(fast: Bool) -> String {
        // Use CPU threads for IO/pre/post stages around GPU
        // Keep some headroom to avoid contention
        let t = systemThreads()
        let base = max(min(t - 2, fast ? 12 : 8), fast ? 4 : 3)
        return "\(base):\(base):\(base)"
    }
    private func runVSRPipeline(input: URL, width: Int, height: Int) {
        // Оптимальный выбор алгоритма по режиму
        currentStepIndex = 1
        switch selectedMode {
        case .fast:
            processWaifu2x(input: input, width: width, height: height)
        case .quality:
            processRealCUGAN(input: input, width: width, height: height)
        }
    }
    private func processVSRCoreML(input: URL, width: Int, height: Int) {
        currentStep = "Обработка через VSR (Core ML)"
        currentStepIndex = 1
        let outputURL = createOutputURL(from: input, suffix: "vsr", width: width, height: height)
        extractFramesAndProcessCoreML(input: input, output: outputURL)
    }
    private func processWaifu2x(input: URL, width: Int, height: Int) {
        currentStep = "Быстрая обработка (Waifu2x)"
        let outputURL = createOutputURL(from: input, suffix: "waifu2x_fast", width: width, height: height)
        extractFramesAndProcess(input: input, output: outputURL, algorithm: "waifu2x")
    }
    private func processRealCUGAN(input: URL, width: Int, height: Int) {
        currentStep = "Качественная обработка (RealCUGAN)"
        let outputURL = createOutputURL(from: input, suffix: "realcugan_quality", width: width, height: height)
        extractFramesAndProcess(input: input, output: outputURL, algorithm: "realcugan")
    }
    // MARK: - Core ML VSR Pipeline (frames -> denoise -> VSR x2 -> assemble)
    private func areCoreMLModelsAvailable() -> Bool {
        let candidates: [URL] = [
            projectRoot().appendingPathComponent("models-coreml"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Coding/MaccyScaler/models-coreml")
        ]
        for base in candidates {
            let fastdvd = base.appendingPathComponent("FastDVDnet.mlmodelc")
            let rbv = base.appendingPathComponent("RealBasicVSR_x2.mlmodelc")
            if FileManager.default.fileExists(atPath: fastdvd.path) && FileManager.default.fileExists(atPath: rbv.path) {
                return true
            }
        }
        return false
    }
    private func extractFramesAndProcessCoreML(input: URL, output: URL) {
        // Создаем временную папку
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MaccyScaler_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            workingTempDir = tempDir
            currentStep = "Извлечение кадров из видео"
            // Извлекаем кадры (JPEG для fast, PNG для quality)
            let extractProcess = Process()
            extractProcess.launchPath = "/opt/homebrew/bin/ffmpeg"
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
                                self.progress = "📤 Извлечение кадров: " + String(format: "%.0f%%", pct * 100)
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
                        self.processFramesWithCoreMLVSR(tempDir: tempDir, originalVideo: input, output: output)
                    } else {
                        self.finishWithError("Ошибка извлечения кадров")
                    }
                }
            }
            currentProcess = extractProcess
            try extractProcess.run()
        } catch {
            finishWithError("Ошибка CoreML-пайплайна: \(error.localizedDescription)")
        }
    }
    private func processFramesWithCoreMLVSR(tempDir: URL, originalVideo: URL, output: URL) {
        currentStep = "Core ML: денойз + VSR"
        let outputFramesDir = tempDir.appendingPathComponent("upscaled")
        do { try FileManager.default.createDirectory(at: outputFramesDir, withIntermediateDirectories: true) } catch {}
        // Собираем список кадров
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == frameExtension })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            finishWithError("Не удалось получить список кадров для Core ML")
            return
        }
        totalFramesCount = files.count
        processedFramesCount = 0
        progressValue = 0
        let context = CIContext()
        let nrFilter = CIFilter.noiseReduction()
        nrFilter.noiseLevel = 0.02
        nrFilter.sharpness = 0.4
        DispatchQueue.global(qos: .userInitiated).async {
            for (idx, url) in files.enumerated() {
                autoreleasepool {
                    guard let inputImage = CIImage(contentsOf: url) else { return }
                    // Денойз (fallback, если FastDVDnet не интегрирован)
                    nrFilter.inputImage = inputImage
                    let denoised = nrFilter.outputImage ?? inputImage
                    // VSR x2 (fallback на Lanczos, пока нет RealBasicVSR Core ML)
                    let lanczos = CIFilter.lanczosScaleTransform()
                    lanczos.inputImage = denoised
                    lanczos.scale = 2.0
                    lanczos.aspectRatio = 1.0
                    let upscaled = lanczos.outputImage ?? denoised
                    // Сохранение
                    let outURL = outputFramesDir.appendingPathComponent(url.lastPathComponent)
                    do {
                        try self.writeImage(upscaled, to: outURL, context: context, ext: self.frameExtension)
                    } catch {
                        DispatchQueue.main.async { self.finishWithError("Ошибка сохранения кадра: \(error.localizedDescription)") }
                        return
                    }
                    // Обновление прогресса
                    DispatchQueue.main.async {
                        self.processedFramesCount = idx + 1
                        let pct = Double(self.processedFramesCount) / Double(max(self.totalFramesCount, 1))
                        self.progressValue = pct
                        self.progress = "🧠 Core ML VSR: " + String(format: "%.0f%% (\(self.processedFramesCount)/\(self.totalFramesCount))", pct * 100)
                        self.updateETAFromFrames(processed: self.processedFramesCount, total: self.totalFramesCount)
                    }
                }
            }
            DispatchQueue.main.async {
                self.reassembleVideo(framesDir: outputFramesDir, originalVideo: originalVideo, output: output, tempDir: tempDir)
            }
        }
    }
    private func writeImage(_ image: CIImage, to url: URL, context: CIContext, ext: String) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw NSError(domain: "MaccyScaler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать CGImage"])
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, (ext == "png" ? kUTTypePNG : kUTTypeJPEG) as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if ext == "jpg" { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "MaccyScaler", code: -2, userInfo: [NSLocalizedDescriptionKey: "Не удалось записать изображение"])
        }
    }
    private func extractFramesAndProcess(input: URL, output: URL, algorithm: String) {
        // Создаем временную папку
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaccyScaler_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            workingTempDir = tempDir
            currentStep = "Извлечение кадров из видео"
            // Извлекаем кадры с помощью ffmpeg
            let extractProcess = Process()
            extractProcess.launchPath = ffmpegPath()
            // Запрашиваем прогресс в stdout
            var args: [String] = [
                "-hide_banner", "-v", "error",
                // Decode as fast as possible on Apple Silicon
                "-hwaccel", "videotoolbox",
                "-threads", "0",
                "-vsync", "0",
                "-progress", "pipe:1",
                "-i", input.path
            ]
            if frameExtension == "jpg" {
                args += ["-q:v", "2", "\(tempDir.path)/%08d.jpg"]
            } else {
                args += ["-compression_level", "0", "\(tempDir.path)/%08d.png"]
            }
            extractProcess.arguments = args
            // Подсчет ETA: используем длительность оригинального видео и out_time_ms прогресса ffmpeg
            extractionTotalDuration = getVideoDuration(url: input)
            let outPipe = Pipe()
            extractProcess.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let lines = text.split(separator: "\n")
                for line in lines {
                    if line.hasPrefix("out_time_ms=") {
                        let valueStr = line.replacingOccurrences(of: "out_time_ms=", with: "")
                        if let outMS = Double(valueStr) {
                            let progressedSec = outMS / 1_000_000.0
                            let duration = max(extractionTotalDuration, 0.0001)
                            let pct = min(max(progressedSec / duration, 0.0), 1.0)
                            DispatchQueue.main.async {
                                self.progressValue = pct
                                self.progress = "📤 Извлечение кадров: " + String(format: "%.0f%%", pct * 100)
                                self.updateETA(percent: pct)
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.appendStdout(text)
                }
            }
            let errPipe = Pipe()
            extractProcess.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self.appendStderr(text)
                }
            }
            extractProcess.terminationHandler = { process in
                DispatchQueue.main.async {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus == 0 {
                        self.currentStepIndex = 2
                        switch algorithm {
                        case "waifu2x":
                            self.processFramesWithWaifu2x(tempDir: tempDir, originalVideo: input, output: output)
                        case "realcugan":
                            self.processFramesWithRealCUGAN(tempDir: tempDir, originalVideo: input, output: output)
                        default:
                            self.processFramesWithWaifu2x(tempDir: tempDir, originalVideo: input, output: output)
                        }
                    } else {
                        self.finishWithError("Ошибка извлечения кадров")
                    }
                }
            }
            currentProcess = extractProcess
            try extractProcess.run()
        } catch {
            finishWithError("Ошибка создания временной папки: \(error.localizedDescription)")
        }
    }
    private func processFramesWithRealESRGAN(tempDir: URL, originalVideo: URL, output: URL) {
        currentStep = "Обработка кадров через Real-ESRGAN"
        let outputFramesDir = tempDir.appendingPathComponent("upscaled")
        do {
            try FileManager.default.createDirectory(at: outputFramesDir, withIntermediateDirectories: true)
            let projectDir = projectRoot()
            let realESRGANPath = projectDir.appendingPathComponent("realesrgan-ncnn-vulkan")
            let modelsPath = projectDir.appendingPathComponent("models")
            // Выбираем модель/масштаб под режим, если доступна x2 — используем её, иначе x4
            var modelName = "realesrgan-x4plus"
            var scaleStr = "4"
            let x2bin = modelsPath.appendingPathComponent("realesrgan-x2plus.bin")
            let x2param = modelsPath.appendingPathComponent("realesrgan-x2plus.param")
            let x2AnimeBin = modelsPath.appendingPathComponent("realesr-animevideov3-x2.bin")
            let x2AnimeParam = modelsPath.appendingPathComponent("realesr-animevideov3-x2.param")
            if selectedMode == .fast {
                if FileManager.default.fileExists(atPath: x2bin.path), FileManager.default.fileExists(atPath: x2param.path) {
                    modelName = "realesrgan-x2plus"
                    scaleStr = "2"
                } else if FileManager.default.fileExists(atPath: x2AnimeBin.path), FileManager.default.fileExists(atPath: x2AnimeParam.path) {
                    modelName = "realesr-animevideov3-x2"
                    scaleStr = "2"
                }
            }
            let process = Process()
            process.launchPath = realESRGANPath.path
            process.currentDirectoryURL = projectDir
            var esrganArgs: [String] = [
                "-i", tempDir.path,
                "-o", outputFramesDir.path,
                "-n", modelName,
                "-s", scaleStr,
                "-f", frameExtension,
                "-m", modelsPath.path,
                "-t", "384",      // больше тайл для скорости, подбирается по VRAM
                "-j", "4:4:4",   // выше параллелизм, можно уменьшить если OOM
                "-g", "0"
            ]
            process.arguments = esrganArgs
            // Проверка наличия исполняемого файла
            guard FileManager.default.isExecutableFile(atPath: realESRGANPath.path) else {
                finishWithError("Не найден исполняемый файл Real-ESRGAN по пути: \(realESRGANPath.path)")
                return
            }
            // Оценка прогресса по количеству обработанных файлов
            self.totalFramesCount = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
            self.processedFramesCount = 0
            self.progressValue = 0
            self.startTime = self.startTime ?? Date()
            self.progressPollTimer?.invalidate()
            self.progressPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let count = (try? FileManager.default.contentsOfDirectory(at: outputFramesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
                self.processedFramesCount = count
                let total = max(self.totalFramesCount, 1)
                let pct = min(max(Double(count) / Double(total), 0.0), 1.0)
                self.progressValue = pct
                self.progress = "🧠 Real-ESRGAN: " + String(format: "%.0f%% (\(count)/\(total))", pct * 100)
                self.updateETAFromFrames(processed: count, total: total)
            }
            // Capture stdout/stderr for error details
            let outPipe = Pipe(); process.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
                    self.progressPollTimer?.invalidate()
                    self.progressPollTimer = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus == 0 {
                        self.reassembleVideo(framesDir: outputFramesDir, originalVideo: originalVideo, output: output, tempDir: tempDir)
                    } else {
                        self.finishWithError("Ошибка обработки Real-ESRGAN")
                    }
                }
            }
            currentProcess = process
            try process.run()
        } catch {
            finishWithError("Ошибка обработки Real-ESRGAN: \(error.localizedDescription)")
        }
    }
    private func processFramesWithRealCUGAN(tempDir: URL, originalVideo: URL, output: URL) {
        currentStep = "Обработка кадров через RealCUGAN"
        let outputFramesDir = tempDir.appendingPathComponent("upscaled")
        do { try FileManager.default.createDirectory(at: outputFramesDir, withIntermediateDirectories: true) } catch {}
        guard let bin = findBinary("realcugan-ncnn-vulkan") else {
            self.finishWithError("Не найден realcugan-ncnn-vulkan. Поместите бинарник в \(self.projectBin().path)")
            return
        }
        let process = Process()
        process.launchPath = bin
        // Параметры под режим
        let (nVal, tile, jobs): (String, String, String) = {
            if selectedMode == .fast {
                return ("0", tunedTileSize(), tunedJobs(fast: true)) // максимум скорости
            } else {
                // Чуть меньше тайл и потоков для стабильности
                let t = tunedTileSize()
                let qualityTile = (Int(t) ?? 512) >= 640 ? "512" : t
                return ("2", qualityTile, tunedJobs(fast: false))
            }
        }()
        process.arguments = [
            "-i", tempDir.path,
            "-o", outputFramesDir.path,
            "-s", "2",
            "-n", nVal,
            "-f", frameExtension,
            "-t", tile,
            "-j", jobs,
            "-g", "0"
        ]
        self.totalFramesCount = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
        self.processedFramesCount = 0
        self.progressValue = 0
        self.startTime = self.startTime ?? Date()
        self.progressPollTimer?.invalidate()
        self.progressPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let count = (try? FileManager.default.contentsOfDirectory(at: outputFramesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
            self.processedFramesCount = count
            let total = max(self.totalFramesCount, 1)
            let pct = min(max(Double(count) / Double(total), 0.0), 1.0)
            self.progressValue = pct
            self.progress = "🚀 RealCUGAN: " + String(format: "%.0f%% (\(count)/\(total))", pct * 100)
            self.updateETAFromFrames(processed: count, total: total)
        }
        let outPipe = Pipe(); process.standardOutput = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty { DispatchQueue.main.async { self.appendStdout(text) } }
        }
        let errPipe = Pipe(); process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty { DispatchQueue.main.async { self.appendStderr(text) } }
        }
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                self.progressPollTimer?.invalidate(); self.progressPollTimer = nil
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    // Проверяем количество обработанных кадров
                    let processedCount = (try? FileManager.default.contentsOfDirectory(at: outputFramesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
                    print("DEBUG: RealCUGAN обработал \(processedCount) кадров в \(outputFramesDir.path)")
                    if processedCount == 0 {
                        self.finishWithError("RealCUGAN не создал ни одного кадра")
                        return
                    }
                    self.reassembleVideo(framesDir: outputFramesDir, originalVideo: originalVideo, output: output, tempDir: tempDir)
                } else {
                    self.finishWithError("Ошибка обработки RealCUGAN")
                }
            }
        }
        do { currentProcess = process; try process.run() } catch { finishWithError("Ошибка запуска RealCUGAN: \(error.localizedDescription)") }
    }
    private func processFramesWithWaifu2x(tempDir: URL, originalVideo: URL, output: URL) {
        currentStep = "Обработка кадров через Waifu2x"
        let outputFramesDir = tempDir.appendingPathComponent("upscaled")
        do { try FileManager.default.createDirectory(at: outputFramesDir, withIntermediateDirectories: true) } catch {}
        guard let bin = findBinary("waifu2x-ncnn-vulkan") else {
            self.finishWithError("Не найден waifu2x-ncnn-vulkan. Поместите бинарник в \(self.projectBin().path)")
            return
        }
        let process = Process()
        process.launchPath = bin
        // Параметры под режим
        let (nW, tileW, jobsW): (String, String, String) = {
            if selectedMode == .fast {
                return ("0", tunedTileSize(), tunedJobs(fast: true)) // скорость
            } else {
                let t = tunedTileSize()
                let qualityTile = (Int(t) ?? 512) >= 640 ? "512" : t
                return ("2", qualityTile, tunedJobs(fast: false)) // качество
            }
        }()
        process.arguments = [
            "-i", tempDir.path,
            "-o", outputFramesDir.path,
            "-s", "2",
            "-n", nW,
            "-f", frameExtension,
            "-t", tileW,
            "-j", jobsW,
            "-g", "0"
        ]
        self.totalFramesCount = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
        self.processedFramesCount = 0
        self.progressValue = 0
        self.startTime = self.startTime ?? Date()
        self.progressPollTimer?.invalidate()
        self.progressPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let count = (try? FileManager.default.contentsOfDirectory(at: outputFramesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
            self.processedFramesCount = count
            let total = max(self.totalFramesCount, 1)
            let pct = min(max(Double(count) / Double(total), 0.0), 1.0)
            self.progressValue = pct
            self.progress = "⚡️ Waifu2x: " + String(format: "%.0f%% (\(count)/\(total))", pct * 100)
            self.updateETAFromFrames(processed: count, total: total)
        }
        let outPipe = Pipe(); process.standardOutput = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty { DispatchQueue.main.async { self.appendStdout(text) } }
        }
        let errPipe = Pipe(); process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty { DispatchQueue.main.async { self.appendStderr(text) } }
        }
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                self.progressPollTimer?.invalidate(); self.progressPollTimer = nil
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    // Проверяем количество обработанных кадров
                    let processedCount = (try? FileManager.default.contentsOfDirectory(at: outputFramesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == self.frameExtension }.count) ?? 0
                    print("DEBUG: Waifu2x обработал \(processedCount) кадров в \(outputFramesDir.path)")
                    if processedCount == 0 {
                        self.finishWithError("Waifu2x не создал ни одного кадра")
                        return
                    }
                    self.reassembleVideo(framesDir: outputFramesDir, originalVideo: originalVideo, output: output, tempDir: tempDir)
                } else {
                    self.finishWithError("Ошибка обработки Waifu2x")
                }
            }
        }
        do { currentProcess = process; try process.run() } catch { finishWithError("Ошибка запуска Waifu2x: \(error.localizedDescription)") }
    }
    private func reassembleVideo(framesDir: URL, originalVideo: URL, output: URL, tempDir: URL) {
        currentStep = "Сборка финального видео"
        currentStepIndex = 3
        
        // Диагностика кадров для сборки
        let frameFiles = (try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == frameExtension }) ?? []
        print("DEBUG: Для сборки найдено \(frameFiles.count) кадров типа .\(frameExtension) в \(framesDir.path)")
        if frameFiles.count > 0 {
            print("DEBUG: Первые 3 файла: \(frameFiles.prefix(3).map { $0.lastPathComponent })")
        }
        // Получаем FPS оригинального видео
        let fps = getVideoFPS(url: originalVideo)
        let process = Process()
        process.launchPath = ffmpegPath()
        var args: [String] = [
            "-hide_banner", "-v", "error",
            "-progress", "pipe:1",
            "-threads", "0",
            "-vsync", "0",
            "-framerate", String(fps),
            "-i", "\(framesDir.path)/%08d.\(self.frameExtension)",
            "-i", originalVideo.path,
        ]
        // Масштаб до целевого разрешения (быстро: bicubic, качество: lanczos)
        let targetName = output.deletingPathExtension().lastPathComponent
        if let xRange = targetName.range(of: #"_(\d+)x(\d+)$"#, options: .regularExpression) {
            let dims = String(targetName[xRange]).dropFirst()
            let parts = dims.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                let filt = (selectedMode == .fast) ? "bicubic" : "lanczos"
                args += ["-vf", "scale=\(w):\(h):flags=\(filt)"]
            }
        }
        args += [
            "-c:v", "hevc_videotoolbox",
            "-preset", (selectedMode == .fast ? "fast" : "medium"),
            "-tag:v", "hvc1",
            "-pix_fmt", "yuv420p",
            "-b:v", (selectedMode == .fast ? "8000k" : "12000k"),
            "-realtime", "1",
            "-movflags", "+faststart",
            "-c:a", "copy",
            "-map", "0:v:0",
            "-map", "1:a:0?",
            "-y",
            output.path
        ]
        process.arguments = args
        // Прогресс сборки по out_time_ms от ffmpeg на основе длительности
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
                            self.progress = "📦 Сборка видео: " + String(format: "%.0f%%", pct * 100)
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
                // Очистка временных файлов
                try? FileManager.default.removeItem(at: tempDir)
                self.workingTempDir = nil
                self.finishProcessing(exitCode: process.terminationStatus)
            }
        }
        do {
            currentProcess = process
            try process.run()
        } catch {
            finishWithError("Ошибка сборки видео: \(error.localizedDescription)")
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
            progress = "✅ Обработка завершена успешно!"
            showSuccessAlert()
        } else {
            progress = "❌ Ошибка обработки (код: \(exitCode))"
            showErrorAlert("Процесс завершился с ошибкой")
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
            print("Ошибка получения размера: \(error)")
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
            print("Ошибка получения FPS: \(error)")
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
            timeElapsed = "\(minutes)м \(seconds)с"
        } else {
            timeElapsed = "\(seconds)с"
        }
    }
    private func updateETAFromFrames(processed: Int, total: Int) {
        guard processed > 0, total > 0 else { etaText = ""; return }
        let now = Date()
        if let lastT = lastRateSampleTime {
            let dt = now.timeIntervalSince(lastT)
            let df = processed - lastRateSampleFrames
            if df > 0 && dt > 0.1 {
                let inst = dt / Double(df) // сек/кадр
                if emaFrameTime == 0 { emaFrameTime = inst } else { emaFrameTime = 0.3 * inst + 0.7 * emaFrameTime }
                let remaining = max(total - processed, 0)
                // не пугаем огромной ETA в самом начале — ждём хотя бы 20 кадров
                if processed < 20 {
                    etaText = "оцениваем..."
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
        guard let start = startTime, percent > 0.01 else { // Увеличили минимум до 1%
            etaText = ""
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed * (1.0 - percent) / percent
        // Защита от огромных времен
        if remaining > 7200 { // Больше 2 часов - не показываем
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
            print("Ошибка получения длительности: \(error)")
        }
        return 0.0
    }
    private func cancelProcessing() {
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
        progress = "⏹ Операция остановлена пользователем"
    }
    private func showSuccessAlert() {
        let alert = NSAlert()
        alert.messageText = "🎉 Обработка завершена!"
        alert.informativeText = "Видео успешно обработано и сохранено рядом с оригинальным файлом"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "❌ Ошибка"
        let details = getErrorSnippet()
        if details.isEmpty {
            alert.informativeText = message
        } else {
            alert.informativeText = message + "\n\nПодробности:\n" + details
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
