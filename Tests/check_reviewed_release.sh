#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
zsh Tests/check_apply_reviewed_map.sh
build_dir="$project_dir/.build/arm64-apple-macosx/release"
sdk_path="$(xcrun --show-sdk-path)"
for item in PrepareReviewedDatabase CommitPreparedDatabase; do
  if [[ "$item" == PrepareReviewedDatabase ]]; then output_name=prepare-reviewed-database; else output_name=commit-prepared-database; fi
  SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" \
  swiftc -parse-as-library -swift-version 6 -sdk "$sdk_path" -I "$build_dir/Modules" \
    "$project_dir/Tests/$item.swift" "$build_dir"/KnowledgeSpineCore.build/*.swift.o -o "$project_dir/.build/$output_name"
done
SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" \
swiftc -parse-as-library -swift-version 6 -sdk "$sdk_path" \
  "$project_dir/Tests/ReviewedReleaseSafetyProbe.swift" -o .build/reviewed-release-safety-probe
.build/reviewed-release-safety-probe
