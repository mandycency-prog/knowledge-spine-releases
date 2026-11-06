#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
if [[ $# -ne 1 || ! -f "$1" ]]; then
  print -u2 "Usage: zsh Tests/check_version_presentation.sh /absolute/path/to/synthetic-fixture/database.json"
  print -u2 "Use a fixture with a complete new-transcript candidate, made by Tests/make_interactive_acceptance_fixture.sh."
  exit 2
fi
fixture_database="${1:A}"
build_dir="$project_dir/.build/arm64-apple-macosx/release"
sdk_path="$(xcrun --show-sdk-path)"
SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" \
swiftc -parse-as-library -swift-version 6 -sdk "$sdk_path" -I "$build_dir/Modules" \
  Tests/VersionPresentationProbe.swift Sources/KnowledgeSpineApp/ImageFiles.swift Sources/KnowledgeSpineApp/AppStore.swift \
  Sources/KnowledgeSpineApp/APICredentials.swift Sources/KnowledgeSpineApp/LocalProcessingService.swift Sources/KnowledgeSpineApp/BoundedLocalProcess.swift \
  Sources/KnowledgeSpineApp/LiveTranscriptionWorker.swift Sources/KnowledgeSpineApp/CaptureService.swift \
  Sources/KnowledgeSpineApp/AudioChunkRecorder.swift Sources/KnowledgeSpineApp/CaptureLifecycleCoordinator.swift \
  "$build_dir"/KnowledgeSpineCore.build/*.swift.o -o .build/version-presentation-probe
.build/version-presentation-probe "$fixture_database"
