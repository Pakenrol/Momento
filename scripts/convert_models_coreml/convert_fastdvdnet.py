#!/usr/bin/env python3
"""
Convert FastDVDnet PyTorch weights to Core ML (.mlmodel), fp16.

Prereqs:
  pip install coremltools==7.0 onnx onnxsim torch torchvision

Usage:
  python convert_fastdvdnet.py --weights path/to/fastdvdnet.pth --out FastDVDnet.mlmodel
"""
import argparse
import coremltools as ct
import torch
import torch.nn as nn

# Placeholder: you must provide a proper FastDVDnet PyTorch module definition
class FastDVDnet(nn.Module):
    def __init__(self):
        super().__init__()
        # TODO: load actual architecture
    def forward(self, x):
        return x

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--weights', required=True)
    ap.add_argument('--out', default='FastDVDnet.mlmodel')
    args = ap.parse_args()

    model = FastDVDnet()
    sd = torch.load(args.weights, map_location='cpu')
    model.load_state_dict(sd)
    model.eval()

    # Example input: N x T x C x H x W (e.g., 1 x 1 x 3 x 360 x 480)
    example = torch.randn(1, 1, 3, 360, 480)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        convert_to='mlprogram',
        inputs=[ct.TensorType(name='input', shape=example.shape)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel = ct.models.neural_network.quantization_utils.quantize_weights(mlmodel, nbits=16)
    mlmodel.save(args.out)

if __name__ == '__main__':
    main()

