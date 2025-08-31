#!/usr/bin/env python3
"""
Проверяем имена входных и выходных параметров CoreML моделей
"""
import coremltools as ct

def check_model(model_path):
    try:
        model = ct.models.MLModel(model_path)
        spec = model.get_spec()
        
        print(f"\n📋 Модель: {model_path}")
        print("📥 Входы:")
        for input_desc in spec.description.input:
            print(f"  - {input_desc.name}: {input_desc.type}")
        
        print("📤 Выходы:")
        for output_desc in spec.description.output:
            print(f"  - {output_desc.name}: {output_desc.type}")
            
    except Exception as e:
        print(f"❌ Ошибка проверки {model_path}: {e}")

if __name__ == "__main__":
    check_model("FastDVDnet.mlpackage")
    check_model("RealBasicVSR_x2.mlpackage")