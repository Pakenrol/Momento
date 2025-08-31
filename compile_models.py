#!/usr/bin/env python3
"""
Компилирует CoreML модели .mlpackage в .mlmodelc
"""
import coremltools as ct
import os

def compile_model(model_path):
    try:
        print(f"🔄 Компилирую {model_path}...")
        model = ct.models.MLModel(model_path)
        output_path = model_path.replace('.mlpackage', '.mlmodelc')
        
        # Компилируем модель
        compiled_url = model.save(output_path)
        print(f"✅ Скомпилировано: {output_path}")
        return True
        
    except Exception as e:
        print(f"❌ Ошибка компиляции {model_path}: {e}")
        return False

def main():
    print("🏗️ Компиляция CoreML моделей...")
    
    models = [
        "FastDVDnet.mlpackage",
        "RealBasicVSR_x2.mlpackage"
    ]
    
    success_count = 0
    for model in models:
        if os.path.exists(model):
            if compile_model(model):
                success_count += 1
        else:
            print(f"❌ Не найден: {model}")
    
    print(f"\n🎯 Результат: {success_count}/{len(models)} моделей скомпилировано")
    
    if success_count == len(models):
        print("🎉 Все модели готовы для использования!")
        return True
    else:
        print("⚠️ Есть проблемы с компиляцией")
        return False

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)