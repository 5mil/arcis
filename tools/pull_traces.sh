#!/bin/sh
# Public reasoning traces that labs posted on Hugging Face (Apache-2.0).
# Not a scraper for unpublished ChatGPT/Grok logs.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=$ROOT/data/traces
mkdir -p "$DEST"
SET=${1:-open-thoughts-114k}

if ! command -v huggingface-cli >/dev/null; then
  echo "pip install -U huggingface_hub"
  echo "then re-run $0"
  exit 1
fi

case $SET in
  open-thoughts-114k|ot)
    huggingface-cli download open-thoughts/OpenThoughts-114k --repo-type dataset --local-dir "$DEST/OpenThoughts-114k"
    ;;
  openr1-math|or)
    huggingface-cli download open-r1/OpenR1-Math-220k --repo-type dataset --local-dir "$DEST/OpenR1-Math-220k"
    ;;
  mot)
    huggingface-cli download open-r1/Mixture-of-Thoughts --repo-type dataset --local-dir "$DEST/Mixture-of-Thoughts"
    ;;
  list)
    echo "ot   OpenThoughts-114k (~114k R1 traces, Apache-2.0)"
    echo "or   OpenR1-Math-220k"
    echo "mot  Mixture-of-Thoughts (~350k, large)"
    ;;
  *)
    echo "usage: $0 ot|or|mot|list"
    exit 1
    ;;
esac
ls -lh "$DEST"
