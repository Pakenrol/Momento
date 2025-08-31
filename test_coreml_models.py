#!/usr/bin/env python3
"""
Тестируем CoreML модели напрямую
"""
import coremltools as ct
import numpy as np
import cv2

def test_models():
    print("🧪 Тестирование CoreML моделей...")
    
    # FastDVDnet
    try:
        print("\n1️⃣ Тестирую FastDVDnet...")
        fastdvd_model = ct.models.MLModel("FastDVDnet.mlpackage")
        
        # Создаем тестовый вход [1, 15, 256, 256]
        test_input = np.random.rand(1, 15, 256, 256).astype(np.float32)
        input_dict = {"noisy": test_input}
        
        # Предсказание
        output = fastdvd_model.predict(input_dict)
        output_array = output["denoised"]
        
        print(f"✅ FastDVDnet: {test_input.shape} -> {output_array.shape}")
        
    except Exception as e:
        print(f"❌ FastDVDnet ошибка: {e}")
    
    # RealBasicVSR
    try:
        print("\n2️⃣ Тестирую RealBasicVSR...")
        rbv_model = ct.models.MLModel("RealBasicVSR_x2.mlpackage")
        
        # Создаем тестовый вход [1, 3, 256, 256]
        test_input = np.random.rand(1, 3, 256, 256).astype(np.float32)
        input_dict = {"input": test_input}
        
        # Предсказание
        output = rbv_model.predict(input_dict)
        output_array = output["output"]
        
        print(f"✅ RealBasicVSR: {test_input.shape} -> {output_array.shape}")
        
    except Exception as e:
        print(f"❌ RealBasicVSR ошибка: {e}")

def test_video_frame():
    """Тест с реальным кадром"""
    try:
        print("\n🎬 Тест с реальным видео кадром...")
        
        # Извлекаем один кадр из тестового видео
        cap = cv2.VideoCapture("test_video.mp4")
        ret, frame = cap.read()
        cap.release()
        
        if not ret:
            print("❌ Не удалось прочитать кадр")
            return
        
        # Подготавливаем кадр для RealBasicVSR
        h, w = frame.shape[:2]
        print(f"Исходный кадр: {w}x{h}")
        
        # Изменяем размер до 256x256 для совместимости с моделью
        frame_resized = cv2.resize(frame, (256, 256))
        
        # BGR -> RGB и нормализация
        frame_rgb = cv2.cvtColor(frame_resized, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        
        # HWC -> NCHW
        frame_tensor = np.transpose(frame_rgb, (2, 0, 1))[np.newaxis, ...]
        
        # Загружаем RealBasicVSR
        rbv_model = ct.models.MLModel("RealBasicVSR_x2.mlpackage")
        
        # Предсказание
        input_dict = {"input": frame_tensor}
        output = rbv_model.predict(input_dict)
        output_array = output["output"]
        
        print(f"✅ Реальный тест: {frame_tensor.shape} -> {output_array.shape}")
        
        # NCHW -> HWC
        output_image = np.transpose(output_array[0], (1, 2, 0))
        output_image = np.clip(output_image * 255, 0, 255).astype(np.uint8)
        
        # RGB -> BGR
        output_bgr = cv2.cvtColor(output_image, cv2.COLOR_RGB2BGR)
        
        # Сохраняем результат
        cv2.imwrite("test_upscaled_frame.png", output_bgr)
        print(f"✅ Сохранен результат: test_upscaled_frame.png ({output_bgr.shape[1]}x{output_bgr.shape[0]})")
        
    except Exception as e:
        print(f"❌ Ошибка теста с кадром: {e}")

if __name__ == "__main__":
    test_models()
    test_video_frame()