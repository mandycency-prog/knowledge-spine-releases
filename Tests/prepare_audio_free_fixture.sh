#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
SDKROOT="$(xcrun --show-sdk-path)" CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" \
swiftc -parse-as-library -swift-version 6 -sdk "$(xcrun --show-sdk-path)" \
  "$project_dir/Tests/PrepareAudioFreeFixture.swift" -o .build/prepare-audio-free-fixture
.build/prepare-audio-free-fixture "$@"
