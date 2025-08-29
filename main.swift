import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - Project Memory/Init
/*
 VidyScaler - Продвинутый видеоапскейлер для реставрации старых видео

 АРХИТЕКТУРА:
 - Real-ESRGAN: Специализация на реставрации реальных видео с зернистостью и артефактами
 - RIFE: Увеличение FPS и интерполяция кадров для плавности
 - FX-Upscale: Простой Metal-апскейлинг (базовый)
 
 ЦЕЛЬ: Превратить зернистые видео 360p из 90х-2000х в четкие HD/4K видео
 
 ПРИНЦИП: Максимальная простота - пользователь перетаскивает файл, выбирает пресет, получает результат
 
 ИНСТРУМЕНТЫ:
 - ~/Documents/coding/VidyScaler/realesrgan-ncnn-vulkan (исполняемый)
 - ~/Documents/coding/VidyScaler/rife/rife-ncnn-vulkan (исполняемый) 
 - /usr/local/bin/fx-upscale (установлен системно)
 
 АЛГОРИТМЫ:
 1. FX-Upscale: Быстрый Metal-апскейлинг
 2. Real-ESRGAN: Реставрация старых видео (убирает зернистость, восстанавливает детали)
 3. RIFE + Real-ESRGAN: Максимальное качество (апскейлинг + интерполяция)
*/

@main
struct VidyScalerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 750, maxWidth: 950, minHeight: 650, maxHeight: 850)
        }
        .windowResizability(.contentSize)
    }
}

enum ProcessingAlgorithm: Int, CaseIterable {
    case fxUpscale = 0
    case realESRGAN = 1
    case rifeRealESRGAN = 2
    
    var name: String {
        switch self {
        case .fxUpscale:
            return "FX-Upscale (быстро)"
        case .realESRGAN:
            return "Real-ESRGAN (реставрация)"
        case .rifeRealESRGAN:
            return "RIFE + Real-ESRGAN (максимум)"
        }
    }
    
    var description: String {
        switch self {
        case .fxUpscale:
            return "Быстрый Metal-апскейлинг для современных видео"
        case .realESRGAN:
            return "AI-реставрация старых видео с зернистостью и артефактами"
        case .rifeRealESRGAN:
            return "Максимальное качество: апскейлинг + интерполяция до 60fps"
        }
    }
}

enum VideoPreset: Int, CaseIterable {
    case classic360to1080 = 0
    case vintage480to4K = 1
    case restoration360to1440 = 2
    case customSize = 3
    
    var name: String {
        switch self {
        case .classic360to1080:
            return "360p → 1080p (классика)"
        case .vintage480to4K:
            return "480p → 4K (винтаж)"
        case .restoration360to1440:
            return "360p → 1440p (реставрация)"
        case .customSize:
            return "Свой размер"
        }
    }
    
    func getTargetSize(originalWidth: Int, originalHeight: Int) -> (Int, Int) {
        switch self {
        case .classic360to1080:
            return (1920, 1080)
        case .vintage480to4K:
            return (3840, 2160)
        case .restoration360to1440:
            return (2560, 1440)
        case .customSize:
            return (originalWidth * 4, originalHeight * 4)
        }
    }
}

struct ContentView: View {
    @State private var selectedFile: URL?
    @State private var isProcessing = false
    @State private var progress: String = ""
    @State private var timeElapsed: String = ""
    @State private var selectedAlgorithm = ProcessingAlgorithm.realESRGAN
    @State private var selectedPreset = VideoPreset.restoration360to1440
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            // Заголовок
            VStack(alignment: .leading, spacing: 8) {
                Text("VidyScaler")
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
            
            // Выбор алгоритма
            VStack(alignment: .leading, spacing: 12) {
                Text("🤖 Алгоритм обработки:")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Picker("Алгоритм", selection: $selectedAlgorithm) {
                    ForEach(ProcessingAlgorithm.allCases, id: \.rawValue) { algorithm in
                        VStack(alignment: .leading) {
                            Text(algorithm.name)
                                .font(.body)
                                .fontWeight(.medium)
                        }
                        .tag(algorithm)
                    }
                }
                .pickerStyle(.segmented)
                
                Text(selectedAlgorithm.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal)
            
            // Выбор пресета
            VStack(alignment: .leading, spacing: 12) {
                Text("🎯 Пресет качества:")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Picker("Пресет", selection: $selectedPreset) {
                    ForEach(VideoPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.name).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280, alignment: .leading)
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
            
            // Информационная панель
            VStack(spacing: 8) {
                Divider()
                ViewThatFits(in: .horizontal) {
                    // Горизонтальный вариант (по умолчанию)
                    HStack {
                        Text("💡 Для старых видео (90-2000е) используйте Real-ESRGAN")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 12)
                        Text("🍎 Оптимизировано для Apple Silicon")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    // Вертикальный фоллбек для узких ширин
                    VStack(alignment: .leading, spacing: 6) {
                        Text("💡 Для старых видео (90-2000е) используйте Real-ESRGAN")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                        Text("🍎 Оптимизировано для Apple Silicon")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
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
        currentStepIndex = 0
        progressValue = 0
        etaText = ""
        processedFramesCount = 0
        totalFramesCount = 0
        resetLogTails()
        emaFrameTime = 0
        lastRateSampleTime = Date()
        lastRateSampleFrames = 0

        // Определяем количество шагов в зависимости от алгоритма
        switch selectedAlgorithm {
        case .fxUpscale:
            totalSteps = 1
        case .realESRGAN:
            totalSteps = 3 // Извлечение кадров + обработка + сборка
        case .rifeRealESRGAN:
            totalSteps = 4 // Извлечение + апскейлинг + интерполяция + сборка
        }
        
        // Запускаем таймер для обновления времени
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            updateProgress()
        }
        
        // Получаем размеры
        let originalSize = getVideoSize(url: inputURL)
        let (targetWidth, targetHeight) = selectedPreset.getTargetSize(originalWidth: originalSize.width, originalHeight: originalSize.height)
        
        // Запускаем соответствующий процесс
        switch selectedAlgorithm {
        case .fxUpscale:
            processFXUpscale(input: inputURL, width: targetWidth, height: targetHeight)
        case .realESRGAN:
            processRealESRGAN(input: inputURL, width: targetWidth, height: targetHeight)
        case .rifeRealESRGAN:
            processRIFERealESRGAN(input: inputURL, width: targetWidth, height: targetHeight)
        }
    }
    
    private func processFXUpscale(input: URL, width: Int, height: Int) {
        currentStep = "Обработка через FX-Upscale"
        currentStepIndex = 1

        let outputURL = createOutputURL(from: input, suffix: "fxupscale", width: width, height: height)

        let process = Process()
        process.launchPath = "/usr/local/bin/fx-upscale"
        process.arguments = [
            input.path,
            "--width", String(width),
            "--height", String(height),
            "--codec", "hevc"
        ]

        process.terminationHandler = { process in
            DispatchQueue.main.async {
                self.finishProcessing(exitCode: process.terminationStatus)
            }
        }

        do {
            currentProcess = process
            try process.run()
        } catch {
            finishWithError("Ошибка запуска FX-Upscale: \(error.localizedDescription)")
        }
    }
    
    private func processRealESRGAN(input: URL, width: Int, height: Int) {
        currentStep = "Обработка через Real-ESRGAN"
        currentStepIndex = 1
        
        let outputURL = createOutputURL(from: input, suffix: "realesrgan", width: width, height: height)
        
        // Real-ESRGAN работает с изображениями, поэтому нужно сначала извлечь кадры
        extractFramesAndProcess(input: input, output: outputURL, algorithm: "realesrgan")
    }
    
    private func processRIFERealESRGAN(input: URL, width: Int, height: Int) {
        currentStep = "Многоэтапная обработка RIFE + Real-ESRGAN"
        currentStepIndex = 1
        
        let outputURL = createOutputURL(from: input, suffix: "rife_realesrgan", width: width, height: height)
        
        // Сложный pipeline: извлечение → Real-ESRGAN → RIFE → сборка
        extractFramesAndProcess(input: input, output: outputURL, algorithm: "rife+realesrgan")
    }
    
    private func extractFramesAndProcess(input: URL, output: URL, algorithm: String) {
        // Создаем временную папку
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidyScaler_\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            workingTempDir = tempDir

            currentStep = "Извлечение кадров из видео"
            currentStepIndex += 1

            // Извлекаем кадры с помощью ffmpeg
            let extractProcess = Process()
            extractProcess.launchPath = "/opt/homebrew/bin/ffmpeg"
            // Запрашиваем прогресс в stdout
            extractProcess.arguments = [
                "-hide_banner", "-v", "error",
                "-progress", "pipe:1",
                "-i", input.path,
                "-compression_level", "0",
                "\(tempDir.path)/%08d.png"
            ]

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
                        if algorithm == "realesrgan" {
                            self.processFramesWithRealESRGAN(tempDir: tempDir, originalVideo: input, output: output)
                        } else {
                            self.processFramesWithRIFERealESRGAN(tempDir: tempDir, originalVideo: input, output: output)
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
        currentStepIndex += 1
        
        let outputFramesDir = tempDir.appendingPathComponent("upscaled")

        do {
            try FileManager.default.createDirectory(at: outputFramesDir, withIntermediateDirectories: true)

            let projectDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/Coding/VidyScaler")

            let realESRGANPath = projectDir.appendingPathComponent("realesrgan-ncnn-vulkan")
            let modelsPath = projectDir.appendingPathComponent("models")

            let process = Process()
            process.launchPath = realESRGANPath.path
            process.currentDirectoryURL = projectDir
            process.arguments = [
                "-i", tempDir.path,
                "-o", outputFramesDir.path,
                "-n", "realesrgan-x4plus", // Модель для реальных изображений
                "-s", "4",
                "-f", "png",
                "-m", modelsPath.path,
                "-t", "256",      // ускорение: тайлинг (скорость/память)
                "-j", "2:2:2",   // ускорение: потоки загрузка:обработка:сохранение
                "-g", "0"         // gpu id
            ]

            // Проверка наличия исполняемого файла
            guard FileManager.default.isExecutableFile(atPath: realESRGANPath.path) else {
                finishWithError("Не найден исполняемый файл Real-ESRGAN по пути: \(realESRGANPath.path)")
                return
            }

            // Оценка прогресса по количеству обработанных файлов
            self.totalFramesCount = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "png" }.count) ?? 0
            self.processedFramesCount = 0
            self.progressValue = 0
            self.startTime = self.startTime ?? Date()
            self.progressPollTimer?.invalidate()
            self.progressPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let count = (try? FileManager.default.contentsOfDirectory(at: outputFramesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "png" }.count) ?? 0
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
    
    private func processFramesWithRIFERealESRGAN(tempDir: URL, originalVideo: URL, output: URL) {
        // Сначала Real-ESRGAN, потом RIFE
        processFramesWithRealESRGAN(tempDir: tempDir, originalVideo: originalVideo, output: output)
    }
    
    private func reassembleVideo(framesDir: URL, originalVideo: URL, output: URL, tempDir: URL) {
        currentStep = "Сборка финального видео"
        currentStepIndex += 1

        // Получаем FPS оригинального видео
        let fps = getVideoFPS(url: originalVideo)

        let process = Process()
        process.launchPath = "/opt/homebrew/bin/ffmpeg"
        process.arguments = [
            "-hide_banner", "-v", "error",
            "-progress", "pipe:1",
            "-framerate", String(fps),
            "-i", "\(framesDir.path)/%08d.png",
            "-i", originalVideo.path,
            // аппаратный энкодер для ускорения сборки на Apple Silicon
            "-c:v", "hevc_videotoolbox",
            "-tag:v", "hvc1",
            "-pix_fmt", "yuv420p",
            "-b:v", "12000k",
            "-c:a", "copy",
            "-map", "0:v:0",
            "-map", "1:a:0?",
            "-y",
            output.path
        ]

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
        process.launchPath = "/opt/homebrew/bin/ffprobe"
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
        process.launchPath = "/opt/homebrew/bin/ffprobe"
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
        let newFilename = "\(filename)_\(suffix)_\(width)x\(height).mp4"
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
        guard let start = startTime, percent > 0.0001 else {
            etaText = ""
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed * (1.0 - percent) / percent
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        etaText = m > 0 ? String(format: "%dm %02ds", m, s) : String(format: "%ds", s)
    }

    private func getVideoDuration(url: URL) -> Double {
        let process = Process()
        process.launchPath = "/opt/homebrew/bin/ffprobe"
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
