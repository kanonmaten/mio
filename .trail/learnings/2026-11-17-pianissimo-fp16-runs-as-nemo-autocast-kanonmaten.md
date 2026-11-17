---
title: Pianissimo FP16 runs as NeMo autocast with FP32 as default until measured on the PC
author: Kanonmaten
date: 2026-11-17
branch: worktree-pianissimo-fp16
cost: { minutes: 12, tokens: 115423 }
id: l-793761d6
scope: repo
status: active
src: agent
touches:
  - docs/STATUS.md
  - transcription-server/mio_transcription/backend.py
  - transcription-server/scripts/measure_wer.py
  - transcription-server/tests/test_precision.py
  - transcription-server/mio_transcription/app.py
  - transcription-server/tests/test_api.py
  - transcription-server/API.md
  - docs/DECISIONS.md
  - transcription-server/tests/test_vocabulary.py
---

## Decided
FP16 for Pianissimo is NeMo's mixed precision (autocast float16 around transcribe), weights stay FP32. Default stays fp32 until the user has run the WER/speed comparison on the GPU; the user's condition was "no worse performance and model updates must keep working".

## Tried and ruled out
- ONNX FP16 (KlangAI/pianissimo-sv-onnx): Sortformer still needs NeMo/PyTorch in the same process, nightly update follows the .nemo repo, word times would have to be built from tokens. Kept as fallback (it has KlangAI's own phrase boosting).
- GGUF F16 (transcribe.cpp, C++): no phrase boosting or word timestamps documented, separate binary.
- model.to(float16) / NeMo compute_dtype: rounds the mel preprocessor's filterbank and window buffers.

## Watch out
Pianissimo's service runs uvicorn with --log-level critical and no logging handler, so log.info never reaches the journal. Expose state through /health (check.sh prints it) instead.

In the code: transcription-server/mio_transcription/backend.py (parse_precision, transcribe), app.py /health "precision", scripts/measure_wer.py --precision fp32 fp16, docs/DECISIONS.md 2026-11-17.
