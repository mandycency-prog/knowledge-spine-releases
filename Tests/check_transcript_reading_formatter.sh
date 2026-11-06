#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
build_dir="$project_dir/.build/arm64-apple-macosx/release"
sdk_path="$(xcrun --show-sdk-path)"
SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" \
swiftc -parse-as-library -swift-version 6 -sdk "$sdk_path" -I "$build_dir/Modules" \
  Tests/TranscriptReadingFormatterProbe.swift Sources/KnowledgeSpineApp/ImageFiles.swift Sources/KnowledgeSpineApp/ExportService.swift \
  "$build_dir"/KnowledgeSpineCore.build/*.swift.o -o .build/transcript-reading-formatter-probe
.build/transcript-reading-formatter-probe
