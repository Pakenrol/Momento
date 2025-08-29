# Core ML Models for VidyScaler

This folder contains conversion scripts to prepare Core ML models for the local pipeline.

Target models:
- FastDVDnet (denoise)
- RealBasicVSR x2 (video super-resolution)

Output layout (place here after conversion):
- `FastDVDnet.mlmodelc/`
- `RealBasicVSR_x2.mlmodelc/`

The app looks for these compiled models at:
`~/Documents/Coding/VidyScaler/models-coreml/`

You can symlink or copy the compiled `.mlmodelc` directories there.

Steps:
1. Create a Python env (Conda or venv) with `coremltools` and frameworks needed to export ONNX from PyTorch.
2. Run the conversion scripts (see below) to produce `.mlmodel`.
3. Compile to `.mlmodelc` with `xcrun coremlc compile`.
4. Copy the compiled directories to `~/Documents/Coding/VidyScaler/models-coreml/`.

