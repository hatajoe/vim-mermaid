#!/bin/sh
# Run the headless test suite: test/run.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
MERMAID_TEST_OUT=$(mktemp)
export MERMAID_TEST_OUT
timeout 120 vim -Nu NONE -es -i NONE \
  --cmd "set rtp^=$root" --cmd 'runtime plugin/mermaid.vim' \
  -S "$root/test/test_mermaid.vim"
rc=$?
cat "$MERMAID_TEST_OUT"
rm -f "$MERMAID_TEST_OUT"
exit $rc
