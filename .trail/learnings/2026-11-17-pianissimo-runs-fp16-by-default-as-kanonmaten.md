---
title: "Pianissimo runs FP16 by default as NeMo autocast, no measurement first"
author: Kanonmaten
date: 2026-11-17
branch: worktree-pianissimo-fp16
cost: { minutes: 1, tokens: 11231 }
id: l-eb12f2ba
scope: repo
status: active
replaces: l-793761d6
src: agent
touches:
  - transcription-server/mio_transcription/backend.py
  - docs/DECISIONS.md
---

## Decided
FP16 for Pianissimo is NeMo's mixed precision (autocast float16 around transcribe), weights stay FP32. The user chose FP16 as the default straight away without a pre-test (2026-11-17), because KlangAI's own FP16 ONNX/GGUF versions match FP32 WER. MIO_PRECISION=fp32 is the way back; measure_wer.py --precision fp32 fp16 compares them.

## Tried and ruled out
- ONNX FP16 (KlangAI/pianissimo-sv-onnx): Sortformer still needs NeMo/PyTorch in the same process, nightly update follows the .nemo repo, word times would have to be built from tokens. Kept as fallback (it has KlangAI's own phrase boosting).
- GGUF F16 (transcribe.cpp, C++): no phrase boosting or word timestamps documented, separate binary.
- model.to(float16) / NeMo compute_dtype: rounds the mel preprocessor's filterbank and window buffers.

## Watch out
Pianissimo's service runs uvicorn with --log-level critical and no logging handler, so log.info never reaches the journal. Expose state through /health (check.sh prints it) instead.

In the code: transcription-server/mio_transcription/backend.py (parse_precision, transcribe), app.py /health "precision", scripts/measure_wer.py --precision fp32 fp16, docs/DECISIONS.md 2026-11-17.
