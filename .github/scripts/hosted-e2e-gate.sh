#!/usr/bin/env bash
set -euo pipefail

case "$IOS_GATE_SHARD" in
  payments) expected=(multi_address_3 multi_address_4 send_1 send_2 send_3 transfer_2) ;;
  channels) expected=(boost_1 boost_2 hardware_wallet_1 hardware_wallet_2 hardware_wallet_4 lightning_1 lnurl_1) ;;
  *) echo "::error::Unknown gate shard"; exit 1 ;;
esac

# Each hosted VM is fresh. Existing locks would let a case skip its first execution.
if compgen -G '/tmp/lock/lock-*' >/dev/null; then
  echo "::error::Unexpected completion locks at the start of the gate"
  exit 1
fi
mkdir -p artifacts
work_dir=$(mktemp -d "${RUNNER_TEMP}/gate-results.XXXXXX")
expected_ids="$work_dir/expected"
passed_ids="$work_dir/passed"
printf '%s\n' "${expected[@]}" | LC_ALL=C sort > "$expected_ids"
touch "$passed_ids"

for attempt in 1 2 3; do
  echo "::group::${IOS_GATE_SHARD} gate attempt ${attempt}"
  log="$work_dir/attempt-$attempt.log"
  result=0
  ATTEMPT="$attempt" ./ci_run_ios.sh --mochaOpts.grep '@ios_gate' 2>&1 | tee "$log" || result=$?
  echo "::endgroup::"
  # WDIO prints a check mark for a passed case and a dash for a retry skip.
  python3 - "$log" "$passed_ids" <<'PY'
import re
import sys

with open(sys.argv[1], errors="replace") as log, open(sys.argv[2], "a") as passed:
    for line in log:
        clean = re.sub(r"\x1b\[[0-9;]*m", "", line)
        match = re.search(r"\[Bitkit\.app iOS #[^\]]+\]\s+[✓✔]\s+@(\w+_\d+)\b", clean, re.I)
        if match:
            print(match[1], file=passed)
PY
  LC_ALL=C sort -u "$passed_ids" -o "$passed_ids"
  count=$(wc -l < "$passed_ids" | tr -d ' ')
  printf '%s attempt %s: %s/%s distinct case passes so far (exit %s)\n' \
    "$IOS_GATE_SHARD" "$attempt" "$count" "${#expected[@]}" "$result" | tee -a artifacts/gate-summary.txt "$GITHUB_STEP_SUMMARY"
  if ((result == 0)); then
    diff -u "$expected_ids" "$passed_ids" || { echo "::error::Gate case IDs do not match this shard"; exit 1; }
    cat "$passed_ids" >> artifacts/gate-summary.txt
    exit 0
  fi
done
exit 1
