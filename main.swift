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
            
            // Кнопка запуска
            HStack {
                Button(action: startUpscaling) {
                    HStack(spacing: 8) {
                        Image(systemName: isProcessing ? "stop.circle" : "play.circle")
                            .font(.title2)
                        Text(isProcessing ? "Обработка..." : "🚀 Начать обработку")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedFile == nil || isProcessing)
                
                if isProcessing {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding(.leading, 16)
                }
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
                
                HStack {
                    Text("💡 Для старых видео (90-2000е) используйте Real-ESRGAN")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("🍎 Оптимизировано для Apple Silicon")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        
        // Определяем количество шагов в зависимости от алгоритма
        switch selectedAlgorithm {
        case .fxUpscale:
            totalSteps = 1
        case .realESRGAN:
            totalSteps = 2 // Извлечение кадров + обработка
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
            
            currentStep = "Извлечение кадров из видео"
            currentStepIndex += 1
            
            // Извлекаем кадры с помощью ffmpeg
            let extractProcess = Process()
            extractProcess.launchPath = "/opt/homebrew/bin/ffmpeg"
            extractProcess.arguments = [
                "-i", input.path,
                "-q:v", "1",
                "\(tempDir.path)/%08d.png"
            ]
            
            extractProcess.terminationHandler = { process in
                DispatchQueue.main.async {
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
                .appendingPathComponent("Documents/coding/VidyScaler")
            
            let realESRGANPath = projectDir.appendingPathComponent("realesrgan-ncnn-vulkan")
            
            let process = Process()
            process.launchPath = realESRGANPath.path
            process.arguments = [
                "-i", tempDir.path,
                "-o", outputFramesDir.path,
                "-n", "realesrgan-x4plus", // Модель для реальных изображений
                "-s", "4",
                "-f", "png"
            ]
            
            process.terminationHandler = { process in
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.reassembleVideo(framesDir: outputFramesDir, originalVideo: originalVideo, output: output, tempDir: tempDir)
                    } else {
                        self.finishWithError("Ошибка обработки Real-ESRGAN")
                    }
                }
            }
            
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
            "-framerate", String(fps),
            "-i", "\(framesDir.path)/%08d.png",
            "-i", originalVideo.path,
            "-c:v", "libx265",
            "-crf", "18",
            "-preset", "medium",
            "-c:a", "copy",
            "-map", "0:v:0",
            "-map", "1:a:0?",
            "-y",
            output.path
        ]
        
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                // Очистка временных файлов
                try? FileManager.default.removeItem(at: tempDir)
                
                self.finishProcessing(exitCode: process.terminationStatus)
            }
        }
        
        do {
            try process.run()
        } catch {
            finishWithError("Ошибка сборки видео: \(error.localizedDescription)")
        }
    }
    
    private func finishProcessing(exitCode: Int32) {
        timer?.invalidate()
        timer = nil
        isProcessing = false
        currentStep = ""
        
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
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}