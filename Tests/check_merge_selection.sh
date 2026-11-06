#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
build_dir="$project_dir/.build/arm64-apple-macosx/release"
sdk_path="$(xcrun --show-sdk-path)"
SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" \
swiftc -parse-as-library -swift-version 6 -sdk "$sdk_path" -I "$build_dir/Modules" \
  Tests/MergeSelectionProbe.swift Sources/KnowledgeSpineApp/MergeAreaView.swift \
  Sources/KnowledgeSpineApp/AppTheme.swift Sources/KnowledgeSpineApp/ImageFiles.swift Sources/KnowledgeSpineApp/AppStore.swift \
  Sources/KnowledgeSpineApp/ExportService.swift Sources/KnowledgeSpineApp/BoundedLocalProcess.swift \
  Sources/KnowledgeSpineApp/APICredentials.swift Sources/KnowledgeSpineApp/LocalProcessingService.swift Sources/KnowledgeSpineApp/LiveTranscriptionWorker.swift \
  Sources/KnowledgeSpineApp/CaptureService.swift Sources/KnowledgeSpineApp/AudioChunkRecorder.swift \
  Sources/KnowledgeSpineApp/CaptureLifecycleCoordinator.swift \
  "$build_dir"/KnowledgeSpineCore.build/*.swift.o -o .build/merge-selection-probe
.build/merge-selection-probe
