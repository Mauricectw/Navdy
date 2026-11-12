#!/usr/bin/env bash
# 在 Linux / macOS 上離線驗證協定邏輯與播放引擎（不需要 Xcode、不需要真音箱）。
# 需求：swiftc（5.9+）、python3。用法：SWIFTC=/path/to/swiftc Tests/run_linux_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
APP=ZonozLocalStream
OUT="$(mktemp -d)"
"$SWIFTC" -swift-version 5 -parse-as-library -O -o "$OUT/harness" \
  $APP/Core/*.swift $APP/Net/LogBus.swift $APP/Net/SonosSoapClient.swift $APP/Net/DeviceProber.swift \
  $APP/Library/Track.swift $APP/Engine/EnginePlatform.swift $APP/Engine/CastEngine.swift \
  Tests/LinuxHarness/*.swift

"$OUT/harness" core

run_engine() {  # $1 = harness 模式, 其餘 = 假音箱參數
  local mode="$1"; shift
  python3 Tests/fake_sonos.py "$@" & local pid=$!
  sleep 1
  local rc=0; "$OUT/harness" "$mode" || rc=$?
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  return $rc
}
echo; echo "### 原生佇列（假音箱一次最多收 16 首）"; run_engine queue
echo; echo "### 原生佇列（假音箱一次最多收 5 首 → 驗證對半拆分後順序仍正確）"; run_engine queue --max-batch 5
echo; echo "### 佇列被拒 → 逐首推送"; run_engine fallback --reject-queue
