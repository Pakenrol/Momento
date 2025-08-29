#!/usr/bin/env python3
"""
Convert RealBasicVSR-x2 PyTorch/ONNX to Core ML (.mlmodel), fp16.

Prereqs:
  pip install coremltools==7.0 onnx onnxsim torch

Usage (from ONNX):
  python convert_realbasicvsr_x2.py --onnx path/to/realbasicvsr_x2.onnx --out RealBasicVSR_x2.mlmodel

Note: RealBasicVSR expects temporal stacks. For Core ML, consider packaging a fixed window (e.g., 8 frames)
and handling windowing/overlap in Swift.
"""
import argparse
import coremltools as ct
import onnx
import onnxsim

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--onnx', required=True)
    ap.add_argument('--out', default='RealBasicVSR_x2.mlmodel')
    args = ap.parse_args()

    model = onnx.load(args.onnx)
    model_simplified, check = onnxsim.simplify(model)
    assert check, 'ONNX simplify failed'

    # Example shape: 1 x T x 3 x H x W with fixed T (e.g., 8)
    T = 8
    example = ct.TensorType(name='input', shape=(1, T, 3, 360, 480))
    mlmodel = ct.convert(
        model_simplified,
        convert_to='mlprogram',
        inputs=[example],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel = ct.models.neural_network.quantization_utils.quantize_weights(mlmodel, nbits=16)
    mlmodel.save(args.out)

if __name__ == '__main__':
    main()

