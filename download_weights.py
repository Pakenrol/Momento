#!/usr/bin/env python3
"""
Скачиваем правильные веса для моделей
"""
import torch
import torch.hub
import requests
import os
from urllib.parse import urlparse

def download_file(url, filename):
    """Скачиваем файл с прогресс-баром"""
    try:
        print(f"Скачиваем {url}")
        response = requests.get(url, stream=True)
        response.raise_for_status()
        
        total_size = int(response.headers.get('content-length', 0))
        downloaded = 0
        
        with open(filename, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total_size > 0:
                        percent = (downloaded / total_size) * 100
                        print(f"\rПрогресс: {percent:.1f}%", end='', flush=True)
        
        print(f"\n✅ Скачано: {filename}")
        return True
    except Exception as e:
        print(f"\n❌ Ошибка скачивания: {e}")
        return False

def download_fastdvdnet_weights():
    """Скачиваем веса FastDVDnet"""
    # Пробуем разные источники
    urls = [
        "https://www.dropbox.com/scl/fi/k6b3f6l1x1mkpq5kcbvo0/fastdvdnet.pth?rlkey=qgp07vn9dqxj3tfrbjdkp7yz1&raw=1",
        "https://zenodo.org/record/4916798/files/fastdvdnet_no_fp16.pth",
        "https://drive.google.com/uc?id=1zEFT1fBnI-aKPE4VBhM6PsGxdlOTf4Vm&export=download"
    ]
    
    for i, url in enumerate(urls):
        print(f"\n🔄 Пробуем источник {i+1}: {url}")
        filename = f"fastdvdnet_weights_{i+1}.pth"
        
        if download_file(url, filename):
            # Проверяем что это правильный файл
            try:
                checkpoint = torch.load(filename, map_location='cpu', weights_only=False)
                if isinstance(checkpoint, dict) or hasattr(checkpoint, 'state_dict'):
                    print(f"✅ Найдены правильные веса FastDVDnet в {filename}")
                    return filename
                else:
                    print(f"❌ {filename} не содержит правильные веса")
                    os.remove(filename)
            except Exception as e:
                print(f"❌ Ошибка проверки {filename}: {e}")
                if os.path.exists(filename):
                    os.remove(filename)
    
    return None

def download_realbasicvsr_weights():
    """Скачиваем веса RealBasicVSR"""
    # Официальные веса из OpenMMLab
    urls = [
        "https://download.openmmlab.com/mmediting/restorers/real_basicvsr/realbasicvsr_c64b20-1x30x8_8xb1-lr5e-5-150k_reds-0f353734.pth",
        "https://download.openmmlab.com/mmediting/restorers/real_basicvsr/realbasicvsr_wogan_c64b20-2x30x8_8xb2-lr1e-4-300k_reds-41795bb0.pth"
    ]
    
    for i, url in enumerate(urls):
        print(f"\n🔄 Пробуем скачать RealBasicVSR источник {i+1}")
        filename = f"realbasicvsr_weights_{i+1}.pth"
        
        if download_file(url, filename):
            # Проверяем файл
            try:
                checkpoint = torch.load(filename, map_location='cpu', weights_only=False)
                if 'state_dict' in checkpoint or 'generator' in checkpoint:
                    print(f"✅ Найдены правильные веса RealBasicVSR в {filename}")
                    return filename
                else:
                    print(f"❌ {filename} не содержит правильную структуру")
                    os.remove(filename)
            except Exception as e:
                print(f"❌ Ошибка проверки {filename}: {e}")
                if os.path.exists(filename):
                    os.remove(filename)
    
    return None

def main():
    print("🚀 Скачивание весов для FastDVDnet и RealBasicVSR")
    
    # Скачиваем FastDVDnet
    print("\n1️⃣ FastDVDnet:")
    fastdvd_weights = download_fastdvdnet_weights()
    if fastdvd_weights:
        # Перемещаем в правильное место
        os.rename(fastdvd_weights, "fastdvdnet_weights.pth")
        print("✅ FastDVDnet веса готовы: fastdvdnet_weights.pth")
    else:
        print("❌ Не удалось скачать веса FastDVDnet")
    
    # Скачиваем RealBasicVSR
    print("\n2️⃣ RealBasicVSR:")
    rbv_weights = download_realbasicvsr_weights()
    if rbv_weights:
        # Перемещаем в правильное место
        os.rename(rbv_weights, "realbasicvsr_weights.pth")
        print("✅ RealBasicVSR веса готовы: realbasicvsr_weights.pth")
    else:
        print("❌ Не удалось скачать веса RealBasicVSR")
    
    print("\n🎯 Результат:")
    if os.path.exists("fastdvdnet_weights.pth"):
        size = os.path.getsize("fastdvdnet_weights.pth") / 1024 / 1024
        print(f"✅ FastDVDnet: {size:.1f} МБ")
    
    if os.path.exists("realbasicvsr_weights.pth"):
        size = os.path.getsize("realbasicvsr_weights.pth") / 1024 / 1024  
        print(f"✅ RealBasicVSR: {size:.1f} МБ")

if __name__ == "__main__":
    main()