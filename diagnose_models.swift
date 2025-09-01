#!/usr/bin/env swift

import Foundation
import CoreML

// Простой скрипт для диагностики CoreML моделей

func getReadableType(_ type: MLFeatureType) -> String {
    switch type {
    case .multiArray:
        return "MultiArray (тензор)"
    case .image:
        return "Image (изображение)"
    case .string:
        return "String (строка)"
    case .int64:
        return "Int64 (число)"
    case .double:
        return "Double (число с плавающей точкой)"
    case .dictionary:
        return "Dictionary (словарь)"
    case .sequence:
        return "Sequence (последовательность)"
    case .invalid:
        return "Invalid (неверный тип)"
    case .state:
        return "State (состояние)"
    @unknown default:
        return "Unknown (\(type))"
    }
}

func getReadableDataType(_ dataType: MLMultiArrayDataType) -> String {
    switch dataType {
    case .double:
        return "Double (64-бит)"
    case .float32:
        return "Float32 (32-бит)"
    case .float16:
        return "Float16 (16-бит)"
    case .int32:
        return "Int32 (32-бит целое)"
    @unknown default:
        return "Unknown (\(dataType))"
    }
}

func diagnoseModel(at url: URL) {
    print("🔍 Диагностика модели: \(url.lastPathComponent)")
    print("📍 Путь: \(url.path)")
    
    do {
        // Конфигурация модели
        let config = MLModelConfiguration()
        if #available(macOS 13.0, *) {
            config.computeUnits = .all
        }
        
        // Компилируем модель если нужно
        let modelURL: URL
        if url.pathExtension == "mlpackage" {
            print("⚙️ Компиляция модели...")
            modelURL = try MLModel.compileModel(at: url)
        } else {
            modelURL = url
        }
        
        // Загружаем модель
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        print("✅ Модель успешно загружена")
        
        // Описание модели
        let description = model.modelDescription
        print("\n📋 Общая информация:")
        print("   Автор: \(description.metadata[.author] as? String ?? "Не указан")")
        print("   Версия: \(description.metadata[.versionString] as? String ?? "Не указана")")
        print("   Описание: \(description.metadata[.description] as? String ?? "Не указано")")
        
        // Входные данные
        print("\n📥 Входные параметры:")
        for (name, feature) in description.inputDescriptionsByName {
            print("   🔸 \(name):")
            print("      Тип: \(getReadableType(feature.type))")
            if case .multiArray = feature.type {
                if let constraints = feature.multiArrayConstraint {
                    print("      Размер: \(constraints.shape)")
                    print("      Тип данных: \(getReadableDataType(constraints.dataType))")
                }
            }
            print("      Опциональный: \(feature.isOptional)")
        }
        
        // Выходные данные
        print("\n📤 Выходные параметры:")
        for (name, feature) in description.outputDescriptionsByName {
            print("   🔸 \(name):")
            print("      Тип: \(getReadableType(feature.type))")
            if case .multiArray = feature.type {
                if let constraints = feature.multiArrayConstraint {
                    print("      Размер: \(constraints.shape)")
                    print("      Тип данных: \(getReadableDataType(constraints.dataType))")
                }
            }
        }
        
        // Проверка совместимости с известными именами параметров
        print("\n🔍 Проверка совместимости:")
        checkCompatibility(description: description, modelName: url.lastPathComponent)
        
        // Попытка запустить модель с тестовыми данными
        print("\n🧪 Тестирование модели...")
        try testModelWithSampleData(model: model)
        
    } catch {
        print("❌ Ошибка: \(error)")
    }
    
    print("\n" + String(repeating: "=", count: 60) + "\n")
}

func checkCompatibility(description: MLModelDescription, modelName: String) {
    if modelName.contains("FastDVDnet") {
        // Проверяем совместимость с FastDVDnet
        let expectedInputs = ["noisy"]
        let expectedOutputs = ["denoised"]
        
        print("   📋 Ожидаемые имена для FastDVDnet:")
        print("      Вход: 'noisy' (5-кадровое окно 15 каналов)")
        print("      Выход: 'denoised' (очищенный центральный кадр)")
        
        let actualInputs = Array(description.inputDescriptionsByName.keys)
        let actualOutputs = Array(description.outputDescriptionsByName.keys)
        
        print("   📋 Фактические имена:")
        print("      Входы: \(actualInputs)")
        print("      Выходы: \(actualOutputs)")
        
        let inputMatch = expectedInputs.contains { actualInputs.contains($0) }
        let outputMatch = expectedOutputs.contains { actualOutputs.contains($0) }
        
        if !inputMatch {
            print("   ⚠️ Несовпадение входов! Используйте '\(actualInputs[0])' вместо 'noisy'")
        }
        if !outputMatch {
            print("   ⚠️ Несовпадение выходов! Используйте '\(actualOutputs[0])' вместо 'denoised'")
        }
        if inputMatch && outputMatch {
            print("   ✅ Имена параметров совместимы")
        }
        
    } else if modelName.contains("RealBasicVSR") {
        // Проверяем совместимость с RealBasicVSR
        let expectedInputs = ["input"]
        let expectedOutputs = ["output"]
        
        print("   📋 Ожидаемые имена для RealBasicVSR:")
        print("      Вход: 'input' (одиночный кадр)")
        print("      Выход: 'output' (увеличенный кадр)")
        
        let actualInputs = Array(description.inputDescriptionsByName.keys)
        let actualOutputs = Array(description.outputDescriptionsByName.keys)
        
        print("   📋 Фактические имена:")
        print("      Входы: \(actualInputs)")
        print("      Выходы: \(actualOutputs)")
        
        let inputMatch = expectedInputs.contains { actualInputs.contains($0) }
        let outputMatch = expectedOutputs.contains { actualOutputs.contains($0) }
        
        if !inputMatch {
            print("   ⚠️ Несовпадение входов! Используйте '\(actualInputs[0])' вместо 'input'")
        }
        if !outputMatch {
            print("   ⚠️ Несовпадение выходов! Используйте '\(actualOutputs[0])' вместо 'output'")
        }
        if inputMatch && outputMatch {
            print("   ✅ Имена параметров совместимы")
        }
    }
}

func testModelWithSampleData(model: MLModel) throws {
    let description = model.modelDescription
    
    // Создаем тестовые входные данные
    var inputDict: [String: MLFeatureValue] = [:]
    
    for (name, feature) in description.inputDescriptionsByName {
        switch feature.type {
        case .multiArray:
            guard let constraints = feature.multiArrayConstraint else { continue }
            let shape = constraints.shape.map { $0.intValue }
            print("   📊 Создание тестовых данных для \(name) с размером \(shape)")
            
            // Создаем массив с случайными значениями от 0 до 1
            let multiArray = try MLMultiArray(shape: constraints.shape, dataType: constraints.dataType)
            let totalElements = shape.reduce(1, *)
            
            for i in 0..<totalElements {
                switch constraints.dataType {
                case .float32:
                    multiArray[i] = NSNumber(value: Float.random(in: 0...1))
                case .double:
                    multiArray[i] = NSNumber(value: Double.random(in: 0...1))
                case .int32:
                    multiArray[i] = NSNumber(value: Int32.random(in: 0...255))
                default:
                    multiArray[i] = NSNumber(value: Float.random(in: 0...1))
                }
            }
            
            inputDict[name] = MLFeatureValue(multiArray: multiArray)
            
        default:
            print("   ⚠️ Неподдерживаемый тип входных данных: \(feature.type)")
            return
        }
    }
    
    // Запускаем предсказание
    let input = try MLDictionaryFeatureProvider(dictionary: inputDict)
    let output = try model.prediction(from: input)
    
    print("   ✅ Модель успешно обработала тестовые данные!")
    
    // Проверяем выходные данные
    for (name, _) in description.outputDescriptionsByName {
        if let outputFeature = output.featureValue(for: name) {
            switch outputFeature.type {
            case .multiArray:
                if let multiArray = outputFeature.multiArrayValue {
                    print("   📊 Выход '\(name)': размер \(multiArray.shape)")
                }
            default:
                print("   📊 Выход '\(name)': тип \(outputFeature.type)")
            }
        }
    }
}

func main() {
    print("🚀 Диагностика CoreML моделей MaccyScaler")
    print(String(repeating: "=", count: 60))
    
    let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    
    // Проверяем FastDVDnet модель
    let fastDVDnetURL = currentDir.appendingPathComponent("FastDVDnet.mlpackage")
    if FileManager.default.fileExists(atPath: fastDVDnetURL.path) {
        diagnoseModel(at: fastDVDnetURL)
    } else {
        print("⚠️ FastDVDnet.mlpackage не найдена в текущей директории")
    }
    
    // Проверяем RealBasicVSR модель
    let realBasicVSRURL = currentDir.appendingPathComponent("RealBasicVSR_x2.mlpackage")
    if FileManager.default.fileExists(atPath: realBasicVSRURL.path) {
        diagnoseModel(at: realBasicVSRURL)
    } else {
        print("⚠️ RealBasicVSR_x2.mlpackage не найдена в текущей директории")
    }
    
    print("🏁 Диагностика завершена!")
}

main()