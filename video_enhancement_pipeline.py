#!/usr/bin/env python3
"""
Готовый CLI pipeline для FastDVDnet + RealBasicVSR x2
Точно по плану: денойзинг -> апскейлинг x2 -> итоговое видео
"""
import os
import sys
import argparse
import torch
import cv2
import numpy as np
from pathlib import Path
import subprocess
import tempfile

def setup_models():
    """Инициализирует модели FastDVDnet и RealBasicVSR"""
    print("🔧 Загрузка моделей...")
    
    models = {}
    
    # Загружаем FastDVDnet (если доступен)
    try:
        if os.path.exists('fastdvdnet_traced.pt'):
            models['fastdvdnet'] = torch.jit.load('fastdvdnet_traced.pt')
            models['fastdvdnet'].eval()
            print("✅ FastDVDnet загружен")
        else:
            print("⚠️ FastDVDnet модель не найдена, пропускаем денойзинг")
    except Exception as e:
        print(f"❌ Ошибка загрузки FastDVDnet: {e}")
        
    # Загружаем RealBasicVSR (если доступен) 
    try:
        if os.path.exists('realbasicvsr_traced.pt'):
            models['realbasicvsr'] = torch.jit.load('realbasicvsr_traced.pt')
            models['realbasicvsr'].eval()
            print("✅ RealBasicVSR загружен")
        else:
            print("⚠️ RealBasicVSR модель не найдена, будем использовать простой upscaling")
    except Exception as e:
        print(f"❌ Ошибка загрузки RealBasicVSR: {e}")
        
    return models

def extract_frames(video_path, output_dir):
    """Извлекает кадры из видео с помощью OpenCV"""
    print(f"🎬 Извлечение кадров из {video_path}")
    
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Не удалось открыть видео: {video_path}")
    
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    
    os.makedirs(output_dir, exist_ok=True)
    frames = []
    
    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
            
        frame_path = os.path.join(output_dir, f"frame_{frame_idx:08d}.png")
        cv2.imwrite(frame_path, frame)
        frames.append(frame_path)
        frame_idx += 1
        
        if frame_idx % 100 == 0:
            print(f"Извлечено {frame_idx}/{total_frames} кадров")
    
    cap.release()
    print(f"✅ Извлечено {len(frames)} кадров")
    return frames, fps

def frames_to_tensor_batch(frame_paths, start_idx, batch_size=5):
    """Конвертирует пачку кадров в тензор для FastDVDnet"""
    frames = []
    
    for i in range(batch_size):
        # Обработка границ - reflect padding
        frame_idx = start_idx - 2 + i  # центральный кадр в позиции 2
        if frame_idx < 0:
            frame_idx = abs(frame_idx)
        elif frame_idx >= len(frame_paths):
            frame_idx = len(frame_paths) - 1 - (frame_idx - len(frame_paths) + 1)
        
        # Загружаем кадр
        frame = cv2.imread(frame_paths[frame_idx])
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        frame = frame.astype(np.float32) / 255.0
        
        # HWC -> CHW
        frame = np.transpose(frame, (2, 0, 1))
        frames.append(frame)
    
    # Объединяем в один тензор: [1, 15, H, W] (5 кадров * 3 канала)
    frames_tensor = torch.from_numpy(np.stack(frames)).unsqueeze(0)
    frames_tensor = frames_tensor.view(1, 15, frames_tensor.shape[-2], frames_tensor.shape[-1])
    
    return frames_tensor

def tensor_to_frame(tensor):
    """Конвертирует тензор обратно в кадр"""
    # [1, 3, H, W] -> [H, W, 3]
    frame = tensor.squeeze(0).permute(1, 2, 0).numpy()
    frame = np.clip(frame * 255, 0, 255).astype(np.uint8)
    return cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)

def denoise_frames(models, frame_paths, output_dir):
    """Денойзинг кадров с помощью FastDVDnet"""
    if 'fastdvdnet' not in models:
        print("⚠️ Пропускаем денойзинг (модель не загружена)")
        return frame_paths
        
    print("🧹 Денойзинг кадров с FastDVDnet...")
    os.makedirs(output_dir, exist_ok=True)
    
    denoised_paths = []
    model = models['fastdvdnet']
    
    for i, frame_path in enumerate(frame_paths):
        # Подготавливаем пачку из 5 кадров
        batch_tensor = frames_to_tensor_batch(frame_paths, i, batch_size=5)
        
        # Денойзинг
        with torch.no_grad():
            denoised_tensor = model(batch_tensor)
        
        # Сохраняем результат
        denoised_frame = tensor_to_frame(denoised_tensor)
        output_path = os.path.join(output_dir, f"denoised_{i:08d}.png")
        cv2.imwrite(output_path, denoised_frame)
        denoised_paths.append(output_path)
        
        if (i + 1) % 50 == 0:
            print(f"Обработано {i+1}/{len(frame_paths)} кадров")
    
    print(f"✅ Денойзинг завершен: {len(denoised_paths)} кадров")
    return denoised_paths

def upscale_frames(models, frame_paths, output_dir):
    """Апскейлинг x2 с помощью RealBasicVSR"""
    print("📈 Апскейлинг x2...")
    os.makedirs(output_dir, exist_ok=True)
    
    upscaled_paths = []
    
    if 'realbasicvsr' in models:
        print("Используется RealBasicVSR для апскейлинга")
        model = models['realbasicvsr']
    else:
        print("Используется простой бикубический апскейлинг")
        model = None
    
    for i, frame_path in enumerate(frame_paths):
        # Загружаем кадр
        frame = cv2.imread(frame_path)
        
        if model is not None:
            # Используем нейронную модель
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
            frame_tensor = torch.from_numpy(np.transpose(frame_rgb, (2, 0, 1))).unsqueeze(0)
            
            with torch.no_grad():
                upscaled_tensor = model(frame_tensor)
            
            upscaled_frame = tensor_to_frame(upscaled_tensor)\n        else:\n            # Простой бикубический апскейлинг\n            h, w = frame.shape[:2]\n            upscaled_frame = cv2.resize(frame, (w*2, h*2), interpolation=cv2.INTER_CUBIC)\n        \n        # Сохраняем результат\n        output_path = os.path.join(output_dir, f\"upscaled_{i:08d}.png\")\n        cv2.imwrite(output_path, upscaled_frame)\n        upscaled_paths.append(output_path)\n        \n        if (i + 1) % 50 == 0:\n            print(f\"Обработано {i+1}/{len(frame_paths)} кадров\")\n    \n    print(f\"✅ Апскейлинг завершен: {len(upscaled_paths)} кадров\")\n    return upscaled_paths\n\ndef create_video(frame_paths, output_path, fps):\n    \"\"\"Создает финальное видео из кадров\"\"\"\n    print(f\"🎥 Создание финального видео: {output_path}\")\n    \n    if not frame_paths:\n        raise ValueError(\"Нет кадров для создания видео\")\n    \n    # Получаем размеры из первого кадра\n    first_frame = cv2.imread(frame_paths[0])\n    height, width = first_frame.shape[:2]\n    \n    # Создаем VideoWriter\n    fourcc = cv2.VideoWriter_fourcc(*'mp4v')\n    out = cv2.VideoWriter(output_path, fourcc, fps, (width, height))\n    \n    for frame_path in frame_paths:\n        frame = cv2.imread(frame_path)\n        out.write(frame)\n    \n    out.release()\n    print(f\"✅ Видео сохранено: {output_path}\")\n\ndef main():\n    parser = argparse.ArgumentParser(description='FastDVDnet + RealBasicVSR x2 Video Enhancement Pipeline')\n    parser.add_argument('input', help='Путь к входному видео')\n    parser.add_argument('--output', '-o', help='Путь к выходному видео', default='enhanced_output.mp4')\n    parser.add_argument('--temp-dir', help='Папка для временных файлов')\n    parser.add_argument('--keep-temp', action='store_true', help='Сохранить временные файлы')\n    \n    args = parser.parse_args()\n    \n    if not os.path.exists(args.input):\n        print(f\"❌ Файл не найден: {args.input}\")\n        sys.exit(1)\n    \n    # Создаем временную директорию\n    if args.temp_dir:\n        temp_base = args.temp_dir\n        os.makedirs(temp_base, exist_ok=True)\n    else:\n        temp_base = tempfile.mkdtemp(prefix='video_enhance_')\n    \n    try:\n        print(f\"🚀 FastDVDnet + RealBasicVSR x2 Pipeline\")\n        print(f\"Входное видео: {args.input}\")\n        print(f\"Выходное видео: {args.output}\")\n        print(f\"Временные файлы: {temp_base}\")\n        \n        # 1. Загружаем модели\n        models = setup_models()\n        \n        # 2. Извлекаем кадры\n        frames_dir = os.path.join(temp_base, 'frames')\n        frame_paths, fps = extract_frames(args.input, frames_dir)\n        \n        # 3. Денойзинг (FastDVDnet)\n        denoised_dir = os.path.join(temp_base, 'denoised')\n        denoised_paths = denoise_frames(models, frame_paths, denoised_dir)\n        \n        # 4. Апскейлинг x2 (RealBasicVSR)\n        upscaled_dir = os.path.join(temp_base, 'upscaled')\n        upscaled_paths = upscale_frames(models, denoised_paths, upscaled_dir)\n        \n        # 5. Создаем финальное видео\n        create_video(upscaled_paths, args.output, fps)\n        \n        print(f\"\\n🎉 Обработка завершена успешно!\")\n        print(f\"Результат: {args.output}\")\n        \n    finally:\n        # Очистка временных файлов\n        if not args.keep_temp and not args.temp_dir:\n            import shutil\n            shutil.rmtree(temp_base)\n            print(f\"🧹 Временные файлы удалены\")\n        else:\n            print(f\"📁 Временные файлы сохранены в: {temp_base}\")\n\nif __name__ == \"__main__\":\n    main()