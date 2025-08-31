#!/usr/bin/env python3
"""
Финальная конвертация обеих моделей в CoreML
"""
import torch
import coremltools as ct
import os

def convert_both_models():
    print("🎯 ФИНАЛЬНАЯ КОНВЕРТАЦИЯ В CoreML")
    print(f"CoreMLTools версия: {ct.__version__}")
    
    success_count = 0
    
    # 1. FastDVDnet (исправленная версия)
    try:
        print("\n1️⃣ Конвертирую FastDVDnet (исправленная версия)...")
        fastdvd_model = torch.jit.load('FastDVDnet_fixed.pt', map_location='cpu')
        fastdvd_model.eval()
        
        fastdvd_coreml = ct.convert(
            fastdvd_model,
            inputs=[ct.TensorType(shape=(1, 15, 256, 256))],
            compute_units=ct.ComputeUnit.ALL,
            convert_to='mlprogram',
            minimum_deployment_target=ct.target.macOS13
        )
        
        fastdvd_coreml.save("FastDVDnet.mlpackage")
        size_mb = sum(os.path.getsize(os.path.join("FastDVDnet.mlpackage", f)) for f in os.listdir("FastDVDnet.mlpackage") if os.path.isfile(os.path.join("FastDVDnet.mlpackage", f))) / 1024 / 1024
        print(f"✅ FastDVDnet.mlpackage создан ({size_mb:.1f} МБ)")
        success_count += 1
        
    except Exception as e:
        print(f"❌ FastDVDnet ошибка: {e}")
    
    # 2. RealBasicVSR
    try:
        print("\n2️⃣ Конвертирую RealBasicVSR...")
        rbv_model = torch.jit.load('RealBasicVSR_final.pt', map_location='cpu')
        rbv_model.eval()
        
        rbv_coreml = ct.convert(
            rbv_model,
            inputs=[ct.TensorType(shape=(1, 3, 256, 256))],
            compute_units=ct.ComputeUnit.ALL,
            convert_to='mlprogram',
            minimum_deployment_target=ct.target.macOS13
        )
        
        rbv_coreml.save("RealBasicVSR_x2.mlpackage")
        if os.path.exists("RealBasicVSR_x2.mlpackage"):
            print(f"✅ RealBasicVSR_x2.mlpackage создан")
            success_count += 1
        
    except Exception as e:
        print(f"❌ RealBasicVSR ошибка: {e}")
    
    print(f"\n🎯 РЕЗУЛЬТАТ: {success_count}/2 модели успешно сконвертированы")
    
    # Проверяем финальные файлы
    models = ["FastDVDnet.mlpackage", "RealBasicVSR_x2.mlpackage"]
    for model in models:
        if os.path.exists(model):
            print(f"✅ {model} - ГОТОВ")
        else:
            print(f"❌ {model} - НЕ СОЗДАН")
    
    return success_count == 2

if __name__ == "__main__":
    success = convert_both_models()
    if success:
        print("\n🎉 ВСЕ МОДЕЛИ УСПЕШНО СКОНВЕРТИРОВАНЫ В CoreML!")
        print("📱 Готовы для использования в macOS приложении!")
    else:
        print("\n⚠️ Есть проблемы с конвертацией")