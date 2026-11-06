#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
build_dir="$project_dir/.build/arm64-apple-macosx/release"
SDKROOT="$(xcrun --show-sdk-path)" \
CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" \
swiftc -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
  -I "$build_dir/Modules" \
  Tests/WorkerRuntime/Probe.swift Sources/KnowledgeSpineApp/LiveTranscriptionWorker.swift \
  "$build_dir"/KnowledgeSpineCore.build/*.swift.o -o .build/worker-runtime-probe
.build/worker-runtime-probe "$1" "${2:-$(command -v python3)}"
