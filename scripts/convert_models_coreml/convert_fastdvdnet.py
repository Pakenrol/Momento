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
    try:
        from fastdvdnet import FastDVDnet
    except Exception as e:
        print('Error: cannot import FastDVDnet. Add the repo to PYTHONPATH or install it.', file=sys.stderr)
        raise
    model = FastDVDnet(num_input_frames=5)
    ckpt = torch.load(weights, map_location='cpu')
    # Support state_dict or full checkpoint dict
    state = ckpt.get('state_dict', ckpt)
    # Strip potential prefixes
    new_state = {}
    for k,v in state.items():
        nk = k
        if nk.startswith('module.'):
            nk = nk[len('module.') :]
        new_state[nk] = v
    model.load_state_dict(new_state, strict=False)
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

    mlmodel = ct.convert(
        traced,
        convert_to='mlprogram',
        inputs=[ct.TensorType(name='input', shape=(1, 15, Hdim, Wdim), dtype=ct.precision.FLOAT32)],
        outputs=[ct.TensorType(name='output', shape=(1, 3, Hdim, Wdim), dtype=ct.precision.FLOAT32)],
        compute_units=ct.ComputeUnit.ALL,
    )
    if args.fp16:
        try:
            mlmodel = ct.models.neural_network.quantization_utils.quantize_weights(mlmodel, nbits=16)
        except Exception:
            pass

    mlmodel.save(args.output)
    print(f'Saved: {args.output}')

if __name__ == '__main__':
    main()

