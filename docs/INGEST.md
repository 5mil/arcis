# Skip = ingest published training

The jump is not “train a foundation model on tank.” It is **take work other people already released** and make Arcis the place it lives.

## Three layers (keep them separate)

| Layer | What you pull | Where it goes |
|-------|----------------|---------------|
| **Weights** | Open GGUF students (R1-Distill 1.5B, Llama-3.2-1B, …) | `models/gguf/` + `--model` |
| **Tasks** | Licensed problem/answer/CoT sets (GSM8K, NuminaMath Apache, OpenMath if you accept NVIDIA) | `data/tasks/` → later LoRA / Algebra War |
| **Books** | OER textbooks (OpenStax CC) | `data/library/` → RAG / Ask |

Weights ≠ books ≠ task rows. Dumping OpenWebMath into the embed index does not replace R1. Fine-tuning on GSM8K does not replace OpenStax citations.

## What “everyone else’s training” legally is

Already-released **artifacts**:

- DeepSeek-R1-Distill-Qwen-1.5B (Apache) — they trained; we load
- Llama 3.2 Instruct GGUF — Meta trained; we load
- GSM8K (MIT) — they labeled; we ingest
- NuminaMath-CoT (Apache-2.0) — they synthesized CoT; we ingest a slice
- OpenStax PDFs — they wrote the book; we RAG

That **is** taking everyone else’s training. The file is the training.

## What it is not

- Scraping ChatGPT / Claude / Grok / Gemini chats to build a private distill set
- Replaying API outputs in violation of those products’ terms
- Pretending Common-Crawl dumps are a single clean license

If a lab did that in the dark, we still do not automate it here.

## Order on this box

1. `./tools/pull_gguf.sh r1-1.5b-q4` — student weights in Arcis
2. MagiMDM `./tools/oer_fetch.sh core` — books + GSM8K (or copy `data/library` next to Arcis)
3. Optional: Numina **slice**, not 860k on day one
4. Optional: `synth_local.sh` against **your** 7B only
5. LoRA last, and only on task rows, not on raw PDFs

## Done

`arcis --model models/gguf/…R1…gguf` loads, library has OpenStax text, GSM8K is on disk. That is the skip. Training from scratch is the long road we are not on.
