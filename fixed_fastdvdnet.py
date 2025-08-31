#!/usr/bin/env python3
"""
Исправленная версия FastDVDnet для CoreML
Убираем проблемные операции
"""
import torch
import torch.nn as nn
import sys
sys.path.insert(0, './fastdvdnet')

from models import FastDVDnet

class FixedFastDVDnetCoreML(torch.nn.Module):
    def __init__(self, fastdvd_model):
        super().__init__()
        self.fastdvd = fastdvd_model
        
    def forward(self, x):
        # x: [1, 15, H, W] - 5 кадров по 3 канала
        B, C, H, W = x.shape
        # Создаем фиксированную карту шума без torch.full
        noise_value = 25.0 / 255.0
        noise_map = torch.zeros(B, 1, H, W, device=x.device, dtype=x.dtype)
        noise_map = noise_map + noise_value  # Простое добавление константы
        return self.fastdvd(x, noise_map)

def create_fixed_fastdvdnet():
    print("🔧 Создание исправленной FastDVDnet модели...")
    
    # Загружаем оригинальную модель
    model = FastDVDnet(num_input_frames=5)
    checkpoint = torch.load('./fastdvdnet/model.pth', map_location='cpu', weights_only=False)
    
    # Очищаем префиксы
    clean_state_dict = {}
    for k, v in checkpoint.items():
        clean_k = k.replace('module.', '')
        clean_state_dict[clean_k] = v
    
    model.load_state_dict(clean_state_dict, strict=False)
    model.eval()
    
    # Создаем исправленную обертку
    wrapped_model = FixedFastDVDnetCoreML(model)
    
    # Трассируем
    example_input = torch.randn(1, 15, 256, 256)
    with torch.no_grad():
        traced_model = torch.jit.trace(wrapped_model, example_input)
    
    # Сохраняем
    torch.jit.save(traced_model, 'FastDVDnet_fixed.pt')
    print("✅ FastDVDnet_fixed.pt сохранен")
    
    # Тестируем
    with torch.no_grad():
        output = traced_model(example_input)
        print(f"✅ Тест: {example_input.shape} -> {output.shape}")
    
    return traced_model

if __name__ == "__main__":
    create_fixed_fastdvdnet()