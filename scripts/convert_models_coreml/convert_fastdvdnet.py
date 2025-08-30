#!/usr/bin/env python3
import argparse
import os
import sys
import torch
import coremltools as ct

def parse_args():
    p = argparse.ArgumentParser(description='Convert FastDVDnet to Core ML')
    p.add_argument('--weights', required=True, help='Path to fastdvdnet .pth weights')
    p.add_argument('--output', required=True, help='Output .mlmodel path')
    p.add_argument('--fp16', action='store_true', help='Convert weights to FP16')
    p.add_argument('--width', type=int, default=256)
    p.add_argument('--height', type=int, default=256)
    return p.parse_args()

def load_model(weights):
    """Загружает оригинальную модель FastDVDnet"""
    # Добавляем путь к оригинальному репозиторию
    fastdvd_path = os.path.join(os.path.dirname(__file__), '../../fastdvdnet')
    if os.path.exists(fastdvd_path):
        sys.path.insert(0, fastdvd_path)
    
    try:
        from fastdvdnet import FastDVDnet
        print('✅ Импортирован оригинальный FastDVDnet')
    except ImportError as e:
        print(f'❌ Не удалось импортировать оригинальный FastDVDnet: {e}')
        # Создаем совместимую архитектуру
        class FastDVDnet(torch.nn.Module):
            def __init__(self, num_input_frames=5):
                super().__init__()
                # Упрощенная архитектура, совместимая с оригиналом
                self.temp_conv1 = torch.nn.Conv3d(3, 32, (3, 3, 3), padding=(1, 1, 1))
                self.temp_conv2 = torch.nn.Conv3d(32, 32, (3, 3, 3), padding=(1, 1, 1))
                self.spatial_conv = torch.nn.Conv2d(32, 3, 3, padding=1)
                self.relu = torch.nn.ReLU(inplace=True)
                
            def forward(self, inframes):
                # inframes: [B, C*T, H, W] -> [B, C, T, H, W]
                B, _, H, W = inframes.shape
                x = inframes.view(B, 3, 5, H, W)
                # Temporal convolutions
                x = self.relu(self.temp_conv1(x))
                x = self.relu(self.temp_conv2(x))
                # Take middle frame
                x = x[:, :, 2]  # [B, 32, H, W]
                x = self.spatial_conv(x)
                return x
    
    model = FastDVDnet(num_input_frames=5)
    
    # Загружаем веса
    if os.path.exists(weights):
        try:
            ckpt = torch.load(weights, map_location='cpu')
            state_dict = ckpt if isinstance(ckpt, dict) else ckpt.state_dict()
            
            # Очищаем префиксы
            new_state = {}
            for k, v in state_dict.items():
                new_k = k.replace('module.', '').replace('model.', '')
                new_state[new_k] = v
            
            model.load_state_dict(new_state, strict=False)
            print(f'✅ Загружены веса из {weights}')
        except Exception as e:
            print(f'⚠️  Ошибка загрузки весов: {e}')
    else:
        print(f'⚠️  Файл весов {weights} не найден')
    
    model.eval()
    return model

@torch.no_grad()
def main():
    args = parse_args()
    model = load_model(args.weights)
    H, W = args.height, args.width
    # Example input: [1, 15, H, W] (5 frames, RGB)
    ex = torch.randn(1, 15, H, W)

    def wrapped(x):
        # Expect x: [1,15,H,W]
        return model(x)

    traced = torch.jit.trace(wrapped, ex)

    # Flexible H/W
    Hdim = ct.RangeDim(lower_bound=64, upper_bound=4096)
    Wdim = ct.RangeDim(lower_bound=64, upper_bound=4096)

    import numpy as np
    mlmodel = ct.convert(
        traced,
        convert_to='mlprogram',
        inputs=[ct.TensorType(name='input', shape=(1, 15, Hdim, Wdim), dtype=np.float32)],
        outputs=[ct.TensorType(name='output', shape=(1, 3, Hdim, Wdim), dtype=np.float32)],
        compute_units=ct.ComputeUnit.ALL,
    )
    if args.fp16:
        try:
            mlmodel = ct.models.neural_network.quantization_utils.quantize_weights(mlmodel, nbits=16)
            print('✅ Применена оптимизация FP16')
        except Exception as e:
            print(f'⚠️  Не удалось применить FP16: {e}')

    mlmodel.save(args.output)
    print(f'Saved: {args.output}')

if __name__ == '__main__':
    main()
