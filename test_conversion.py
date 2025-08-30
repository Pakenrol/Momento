#!/usr/bin/env python3
"""
Тестовый скрипт для конвертации FastDVDnet и RealBasicVSR в CoreML
"""
import os
import subprocess
import sys

def run_conversion_test():
    """Тестирует конвертацию моделей"""
    print("🧪 Тестирование конвертации моделей в CoreML")
    
    # Путь к скриптам
    scripts_dir = "scripts/convert_models_coreml"
    models_dir = "converted_models"
    os.makedirs(models_dir, exist_ok=True)
    
    # Тест FastDVDnet
    print("\n1️⃣ Тестирование FastDVDnet...")
    fastdvd_weights = "fastdvdnet/fastdvdnet.pth"
    fastdvd_output = f"{models_dir}/FastDVDnet.mlmodel"
    
    try:
        cmd = [
            sys.executable,
            f"{scripts_dir}/convert_fastdvdnet.py",
            "--weights", fastdvd_weights,
            "--output", fastdvd_output,
            "--width", "512",
            "--height", "512",
            "--fp16"
        ]
        print(f"Выполняем: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode == 0:
            print("✅ FastDVDnet успешно конвертирован!")
            print(result.stdout)
        else:
            print("❌ Ошибка конвертации FastDVDnet:")
            print(result.stderr)
            
    except Exception as e:
        print(f"❌ Исключение при конвертации FastDVDnet: {e}")
    
    # Тест RealBasicVSR
    print("\n2️⃣ Тестирование RealBasicVSR...")
    rbv_weights = "realbasicvsr_x2.pth"
    rbv_output = f"{models_dir}/RealBasicVSR_x2.mlmodel"
    
    try:
        cmd = [
            sys.executable, 
            f"{scripts_dir}/convert_realbasicvsr_x2.py",
            "--weights", rbv_weights,
            "--output", rbv_output,
            "--width", "256", 
            "--height", "256",
            "--fp16"
        ]
        print(f"Выполняем: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode == 0:
            print("✅ RealBasicVSR успешно конвертирован!")
            print(result.stdout)
        else:
            print("❌ Ошибка конвертации RealBasicVSR:")
            print(result.stderr)
            
    except Exception as e:
        print(f"❌ Исключение при конвертации RealBasicVSR: {e}")
    
    # Проверяем результаты
    print("\n📋 Результаты:")
    for model_name in ["FastDVDnet.mlmodel", "RealBasicVSR_x2.mlmodel"]:
        model_path = os.path.join(models_dir, model_name)
        if os.path.exists(model_path):
            size_mb = os.path.getsize(model_path) / (1024 * 1024)
            print(f"✅ {model_name}: {size_mb:.1f} МБ")
        else:
            print(f"❌ {model_name}: не найден")

if __name__ == "__main__":
    run_conversion_test()