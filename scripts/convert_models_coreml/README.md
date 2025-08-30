Core ML model conversion for MaccyScaler

Overview
- Converts FastDVDnet (denoise) and RealBasicVSR x2 (super-resolution) from PyTorch to Core ML (.mlmodel), then compiles to .mlmodelc for use in the app/CLI.
- You need Python 3.9+ on macOS with Xcode installed (for coremlc compilation).

Directory
- convert_fastdvdnet.py — converts FastDVDnet .pth → .mlmodel
- convert_realbasicvsr_x2.py — converts RealBasicVSR x2 .pth → .mlmodel
- requirements.txt — Python deps
- compile_coreml.sh — helper to compile .mlmodel → .mlmodelc

1) Install dependencies
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt

Note: For RealBasicVSR you also need MMEditing and MMCV:
pip install mmcv==2.0.0 mmdet==3.0.0 mmedit==1.0.0

or follow MMEditing’s installation docs matching your PyTorch version.

2) Prepare weights
- FastDVDnet: Download fastdvdnet.pth from the official repo or a trained checkpoint.
  Repo: https://github.com/m-tassano/fastdvdnet

- RealBasicVSR x2: Use a trained x2 checkpoint (e.g., official RealBasicVSR weights) compatible with MMEditing.
  Repo: https://github.com/open-mmlab/mmediting

Place weights in this folder or pass absolute paths in --weights.

3) Convert FastDVDnet
python convert_fastdvdnet.py \
  --weights fastdvdnet.pth \
  --output FastDVDnet.mlmodel \
  --fp16

Input/Output
- Input: Tensor [1, 15, H, W] (5 frames, 3 channels each, NCHW) normalized to 0..1
- Output: Tensor [1, 3, H, W] — denoised center frame

4) Convert RealBasicVSR x2
python convert_realbasicvsr_x2.py \
  --config /path/to/realbasicvsr_config.py \
  --weights realbasicvsr_x2.pth \
  --output RealBasicVSR_x2.mlmodel \
  --fp16

Notes
- For simplicity this exporter wraps inference as single-frame x2 SR (uses the model’s generator on one frame). This provides a working Core ML super-resolution step. For full temporal modeling, export a recurrent or unrolled graph and adapt the Swift runner accordingly.

5) Compile models to .mlmodelc
./compile_coreml.sh FastDVDnet.mlmodel ../..//models-coreml/FastDVDnet.mlmodelc
./compile_coreml.sh RealBasicVSR_x2.mlmodel ../..//models-coreml/RealBasicVSR_x2.mlmodelc

6) Test the CoreML CLI
From repo root:
swift build -c release
.build/release/coreml-vsr-cli \
  --input test_video.mp4 \
  --models models-coreml

Outputs: <input>_coreml_x2.mp4 next to the input.

Troubleshooting
- If conversion fails on unsupported ops, try:
  - Export through ONNX first, then ct.convert on ONNX.
  - Use fp16 (--fp16) to reduce memory and enable ANE
  - Reduce dynamic shape usage: export at 256×256 and allow flexible H/W via ct.RangeDim where possible.
- Ensure Xcode command line tools are installed: xcode-select --install

