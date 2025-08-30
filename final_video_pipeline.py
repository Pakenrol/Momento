#!/usr/bin/env python3
"""
Финальный pipeline FastDVDnet + RealBasicVSR
ТОЧНО ПО ПЛАНУ: оригинальные модели, денойзинг → апскейлинг x2
"""
import os
import sys
import argparse
import torch
import cv2
import numpy as np
from pathlib import Path

def load_models():
    """Загружает оригинальные traced модели"""
    models = {}
    
    # FastDVDnet
    fastdvd_path = "fastdvdnet_traced.pt"
    if os.path.exists(fastdvd_path):
        try:
            models['fastdvd'] = torch.jit.load(fastdvd_path, map_location='cpu')
            models['fastdvd'].eval()
            print("✅ FastDVDnet загружен из traced модели")
        except Exception as e:
            print(f"❌ Ошибка загрузки FastDVDnet: {e}")
    else:
        print("⚠️ fastdvdnet_traced.pt не найден")
    
    # RealBasicVSR 
    rbv_path = "realbasicvsr_traced.pt"
    if os.path.exists(rbv_path):
        try:
            models['realbasicvsr'] = torch.jit.load(rbv_path, map_location='cpu')
            models['realbasicvsr'].eval()
            print("✅ RealBasicVSR загружен из traced модели")
        except Exception as e:
            print(f"❌ Ошибка загрузки RealBasicVSR: {e}")
    else:
        print("⚠️ realbasicvsr_traced.pt не найден")
    
    return models

def create_frame_batch(frames, center_idx, batch_size=5):
    """Создает пачку из 5 кадров для FastDVDnet"""
    batch = []
    half_batch = batch_size // 2  # 2 for 5-frame window
    
    for i in range(batch_size):
        frame_idx = center_idx - half_batch + i
        
        # Обработка границ (reflection padding)
        if frame_idx < 0:
            frame_idx = abs(frame_idx)
        elif frame_idx >= len(frames):
            frame_idx = len(frames) - 1 - (frame_idx - len(frames) + 1)
        
        frame_idx = max(0, min(len(frames) - 1, frame_idx))
        batch.append(frames[frame_idx])
    
    return batch

def frames_to_tensor_batch(frame_batch):
    """Конвертирует пачку кадров в тензор [1, 15, H, W]"""
    tensors = []
    
    for frame in frame_batch:
        # BGR -> RGB
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        # Normalize to [0, 1]
        frame_normalized = frame_rgb.astype(np.float32) / 255.0
        # HWC -> CHW
        frame_tensor = torch.from_numpy(np.transpose(frame_normalized, (2, 0, 1)))
        tensors.append(frame_tensor)
    
    # Stack to [5, 3, H, W] then reshape to [1, 15, H, W]
    batch_tensor = torch.stack(tensors)  # [5, 3, H, W]
    batch_tensor = batch_tensor.view(1, 15, batch_tensor.shape[-2], batch_tensor.shape[-1])
    
    return batch_tensor

def tensor_to_frame(tensor):
    """Конвертирует тензор обратно в кадр"""
    # [1, 3, H, W] -> [H, W, 3]
    frame = tensor.squeeze(0).permute(1, 2, 0).numpy()
    frame = np.clip(frame * 255, 0, 255).astype(np.uint8)
    # RGB -> BGR
    return cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)

def process_video_pipeline(input_path, output_path, models):
    """Основной pipeline: загрузка → денойзинг → апскейлинг → сохранение"""
    
    print(f"🎬 Загрузка видео: {input_path}")
    cap = cv2.VideoCapture(input_path)
    if not cap.isOpened():
        raise ValueError(f"Не удалось открыть видео: {input_path}")
    
    # Читаем все кадры
    frames = []
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    
    print(f"📊 FPS: {fps}, Всего кадров: {total_frames}")
    
    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        frames.append(frame)
        frame_idx += 1
        
        if frame_idx % 100 == 0:
            print(f"Загружено {frame_idx} кадров...")
    
    cap.release()
    print(f"✅ Загружено {len(frames)} кадров")
    
    # Этап 1: Денойзинг с FastDVDnet
    denoised_frames = []
    if 'fastdvd' in models:
        print("🧹 Денойзинг с FastDVDnet (5-кадровые окна)...")
        
        for i in range(len(frames)):
            # Создаем пачку из 5 кадров
            frame_batch = create_frame_batch(frames, i, batch_size=5)
            batch_tensor = frames_to_tensor_batch(frame_batch)
            
            # Денойзинг
            with torch.no_grad():
                try:
                    denoised_tensor = models['fastdvd'](batch_tensor)
                    denoised_frame = tensor_to_frame(denoised_tensor)
                    denoised_frames.append(denoised_frame)
                except Exception as e:
                    print(f"❌ Ошибка денойзинга кадра {i}: {e}")
                    denoised_frames.append(frames[i])  # Fallback
            
            if (i + 1) % 50 == 0:
                print(f"Денойзинг: {i+1}/{len(frames)} кадров")
        
        print(f"✅ Денойзинг завершен: {len(denoised_frames)} кадров")
    else:
        print("⚠️ Пропускаем денойзинг (модель не загружена)")
        denoised_frames = frames.copy()
    
    # Этап 2: Апскейлинг x2 с RealBasicVSR
    upscaled_frames = []
    if 'realbasicvsr' in models:
        print("📈 Апскейлинг x2 с RealBasicVSR...")
        
        for i, frame in enumerate(denoised_frames):
            # Подготовка кадра
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
            frame_tensor = torch.from_numpy(np.transpose(frame_rgb, (2, 0, 1))).unsqueeze(0)
            
            # Апскейлинг
            with torch.no_grad():
                try:
                    upscaled_tensor = models['realbasicvsr'](frame_tensor)
                    upscaled_frame = tensor_to_frame(upscaled_tensor)
                    upscaled_frames.append(upscaled_frame)
                except Exception as e:
                    print(f"❌ Ошибка апскейлинга кадра {i}: {e}")
                    # Fallback на простой bicubic
                    h, w = frame.shape[:2]
                    upscaled_frame = cv2.resize(frame, (w*2, h*2), interpolation=cv2.INTER_CUBIC)
                    upscaled_frames.append(upscaled_frame)
            
            if (i + 1) % 50 == 0:
                print(f"Апскейлинг: {i+1}/{len(denoised_frames)} кадров")
        
        print(f"✅ Апскейлинг завершен: {len(upscaled_frames)} кадров")
    else:
        print("⚠️ Пропускаем апскейлинг (модель не загружена), используем простой x2")
        for frame in denoised_frames:
            h, w = frame.shape[:2]
            upscaled_frame = cv2.resize(frame, (w*2, h*2), interpolation=cv2.INTER_CUBIC)
            upscaled_frames.append(upscaled_frame)
    
    # Этап 3: Сохранение видео
    if upscaled_frames:
        print(f"🎥 Сохранение видео: {output_path}")
        
        h, w = upscaled_frames[0].shape[:2]
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        out = cv2.VideoWriter(output_path, fourcc, fps, (w, h))
        
        for frame in upscaled_frames:
            out.write(frame)
        
        out.release()
        print(f"✅ Видео сохранено: {output_path}")
        print(f"📊 Размер: {w}x{h}, FPS: {fps}")
    else:
        print("❌ Нет кадров для сохранения")

def main():
    parser = argparse.ArgumentParser(description='FastDVDnet + RealBasicVSR Pipeline - ТОЧНО ПО ПЛАНУ')
    parser.add_argument('input', help='Входное видео')
    parser.add_argument('--output', '-o', help='Выходное видео')
    parser.add_argument('--models-dir', default='.', help='Папка с traced моделями')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.input):
        print(f"❌ Файл не найден: {args.input}")
        sys.exit(1)
    
    if not args.output:
        input_path = Path(args.input)
        args.output = str(input_path.with_name(f"{input_path.stem}_enhanced{input_path.suffix}"))
    
    print("🚀 FastDVDnet + RealBasicVSR Pipeline")
    print("📍 ТОЧНО ПО ПЛАНУ: денойзинг → апскейлинг x2")
    print(f"📥 Вход: {args.input}")
    print(f"📤 Выход: {args.output}")
    print(f"📁 Модели: {args.models_dir}")
    
    # Переходим в папку с моделями
    old_cwd = os.getcwd()
    if args.models_dir != '.':
        os.chdir(args.models_dir)
    
    try:
        # Загружаем модели
        models = load_models()
        
        if not models:
            print("❌ Не загружена ни одна модель!")
            print("Убедитесь что есть файлы:")
            print("  - fastdvdnet_traced.pt")  
            print("  - realbasicvsr_traced.pt")
            sys.exit(1)
        
        # Запускаем pipeline
        process_video_pipeline(os.path.join(old_cwd, args.input), 
                              os.path.join(old_cwd, args.output), 
                              models)
        
        print("\\n🎉 Pipeline успешно завершен!")
        print(f"Результат: {args.output}")
        print("\\nРезультат: максимально натуральный отремастеренный видео!")
        
    finally:
        os.chdir(old_cwd)

if __name__ == "__main__":
    main()