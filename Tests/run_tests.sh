#!/usr/bin/env bash
# 離線驗證：純邏輯、真的 HTTP 伺服器、播放引擎對假音箱。Linux / macOS / Windows(Git Bash) 都能跑。
# 需求：dotnet 8 SDK、python3。額外的 dotnet 參數可用 DOTNET_BUILD_ARGS 傳入。
set -uo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"; command -v "$PY" >/dev/null 2>&1 || PY=python
dotnet build Zonoz.Tests -c Release ${DOTNET_BUILD_ARGS:-} -o Tests/out >/tmp/zonoz-build.log 2>&1 || { tail -n 30 /tmp/zonoz-build.log; exit 1; }
RUN="dotnet Tests/out/Zonoz.Tests.dll"
fail=0
$RUN core || fail=1
$RUN http || fail=1
run_engine() {  # $1 = 模式, 其餘 = 假音箱參數
  local mode="$1"; shift
  "$PY" Tests/fake_sonos.py --fetch "$@" & local pid=$!
  sleep 1.5
  $RUN "$mode" || fail=1
  curl -s -m 3 -X POST http://127.0.0.1:1400/__quit >/dev/null 2>&1   # Windows 上 kill 不一定殺得掉原生行程
  sleep 0.5; kill $pid 2>/dev/null; wait $pid 2>/dev/null
}
echo; echo "### 原生佇列（假音箱一次最多收 16 首）"; run_engine queue
echo; echo "### 原生佇列（假音箱一次最多收 5 首 → 驗證對半拆分後順序仍正確）"; run_engine queue --max-batch 5
echo; echo "### 佇列被拒 → 逐首推送"; run_engine fallback --reject-queue
exit $fail
