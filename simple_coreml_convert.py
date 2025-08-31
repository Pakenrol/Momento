#!/usr/bin/env python3
"""
Простая конвертация traced моделей в CoreML
Максимально упрощенный подход
"""
import torch
import coremltools as ct
import numpy as np

def convert_traced_models():
    print("🔄 Простая конвертация traced моделей в CoreML...")
    print(f"CoreMLTools версия: {ct.__version__}")
    
    # FastDVDnet
    try:
        print("1️⃣ Конвертирую FastDVDnet...")
        fastdvd_model = torch.jit.load('FastDVDnet_final.pt', map_location='cpu')
        fastdvd_model.eval()
        
        # Простая конвертация с минимальными параметрами
        fastdvd_coreml = ct.convert(
            fastdvd_model,
            inputs=[ct.TensorType(shape=(1, 15, 256, 256))],
            compute_units=ct.ComputeUnit.ALL,
            convert_to='mlprogram',
            minimum_deployment_target=ct.target.macOS13
        )
        
        fastdvd_coreml.save("FastDVDnet.mlpackage")
        print("✅ FastDVDnet.mlmodel создан")
        
    except Exception as e:
        print(f"❌ FastDVDnet ошибка: {e}")
    
    # RealBasicVSR  
    try:
        print("2️⃣ Конвертирую RealBasicVSR...")
        rbv_model = torch.jit.load('RealBasicVSR_final.pt', map_location='cpu')
        rbv_model.eval()
        
        # Простая конвертация с минимальными параметрами
        rbv_coreml = ct.convert(
            rbv_model,
            inputs=[ct.TensorType(shape=(1, 3, 256, 256))],
            compute_units=ct.ComputeUnit.ALL,
            convert_to='mlprogram',
            minimum_deployment_target=ct.target.macOS13
        )
        
        rbv_coreml.save("RealBasicVSR_x2.mlpackage")
        print("✅ RealBasicVSR_x2.mlmodel создан")
        
    except Exception as e:
        print(f"❌ RealBasicVSR ошибка: {e}")

if __name__ == "__main__":
    convert_traced_models()