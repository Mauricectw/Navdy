#!/usr/bin/env bash
# Runs a command, keeps its full output in $LOG, and on failure publishes the relevant lines as a
# single ::error annotation (annotations are readable through the GitHub API, raw logs may not be).
# usage: run-and-annotate.sh LOGFILE TITLE -- command args...
set -uo pipefail
LOG="$1"; TITLE="$2"; shift 3
"$@" > "$LOG" 2>&1
status=$?
tail -n 40 "$LOG"
if [ $status -ne 0 ]; then
  lines=$(grep -E "error:|error |fatal|failed|XCTAssert|Fatal error|Testing failed|ld: |undefined" "$LOG" \
          | grep -v "^\s*$" | awk '!seen[$0]++' | head -n 60)
  [ -z "$lines" ] && lines=$(tail -n 40 "$LOG")
  msg=$(printf '%s' "$lines" | sed -e 's/%/%25/g' -e 's/\r//g' | awk 'BEGIN{ORS="%0A"} {print}')
  echo "::error title=${TITLE}::${msg}"
fi
exit $status
