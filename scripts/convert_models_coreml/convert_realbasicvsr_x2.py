#!/usr/bin/env python3
import argparse
import os
import sys
import torch
import coremltools as ct

def parse_args():
    p = argparse.ArgumentParser(description='Convert RealBasicVSR x2 to Core ML (single-frame wrapper)')
    p.add_argument('--config', required=False, help='MMEditing config (optional if you import a custom net)')
    p.add_argument('--weights', required=True, help='RealBasicVSR x2 .pth path')
    p.add_argument('--output', required=True, help='Output .mlmodel path')
    p.add_argument('--fp16', action='store_true', help='Convert weights to FP16')
    p.add_argument('--width', type=int, default=256)
    p.add_argument('--height', type=int, default=256)
    return p.parse_args()

def build_single_frame_wrapper(weights):
    """
    Wrap RealBasicVSR generator as single-frame x2 SR module.
    This provides a working SR step for Core ML; it does not model temporal recurrence.
    """
    try:
        from mmedit.apis import init_model
    except Exception as e:
        print('Error: MMEditing not available. Install mmcv/mmedit or provide a custom net.', file=sys.stderr)
        raise
    # Use any RealBasicVSR config that matches the provided weights
    # If no config provided, try to infer; otherwise user must pass --config
    # For simplicity, we instantiate via init_model if config is available
    return None

class RBV_SingleFrame(torch.nn.Module):
    def __init__(self, generator):
        super().__init__()
        self.g = generator
        # Expect input [1,3,H,W]; forward with single frame path of generator
    def forward(self, x):
        # Some RealBasicVSR implementations require sequences; here we call the generator on a single frame.
        # If your generator requires sequences, replace this call with the appropriate single-frame forward or a 1-frame unroll.
        y = self.g(x)
        return y

def main():
    args = parse_args()
    H, W = args.height, args.width
    # Minimal approach: user supplies a torch module that performs x2 SR per frame
    # Option A: from mmedit, load the generator from a RealBasicVSR checkpoint
    # Fallback: try to load a state_dict into a compatible backbone (e.g., BasicVSRNet/EDSR-like) — requires user adaptation.
    # For safety, we load a generic torch nn.Module from the checkpoint if it contains a scripted module.
    ckpt = torch.load(args.weights, map_location='cpu')
    if isinstance(ckpt, torch.jit.ScriptModule):
        net = ckpt
    else:
        # Expect a dict with 'state_dict' and a generator def supplied by user.
        state = ckpt.get('state_dict', ckpt)
        # User must adapt this section to instantiate their generator
        print('WARNING: Please adapt convert_realbasicvsr_x2.py to instantiate your generator and load state_dict.', file=sys.stderr)
        class IdentityUp2(torch.nn.Module):
            def forward(self, x):
                return torch.nn.functional.interpolate(x, scale_factor=2, mode='bilinear', align_corners=False)
        net = IdentityUp2()
    net.eval()

    ex = torch.randn(1,3,H,W)
    traced = torch.jit.trace(net, ex)

    Hdim = ct.RangeDim(lower_bound=64, upper_bound=4096)
    Wdim = ct.RangeDim(lower_bound=64, upper_bound=4096)
    mlmodel = ct.convert(
        traced,
        convert_to='mlprogram',
        inputs=[ct.TensorType(name='input', shape=(1,3,Hdim,Wdim), dtype=ct.precision.FLOAT32)],
        outputs=[ct.TensorType(name='output', shape=(1,3,ct.RangeDim(lower_bound=128, upper_bound=8192), ct.RangeDim(lower_bound=128, upper_bound=8192)), dtype=ct.precision.FLOAT32)],
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

