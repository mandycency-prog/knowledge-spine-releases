#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
CLANG_MODULE_CACHE_PATH="$project_dir/.build/swift-cache" swiftc -parse-as-library -swift-version 6 \
  Sources/KnowledgeSpineApp/AppInstanceLease.swift Tests/AppInstanceLeaseProbe.swift -o .build/app-instance-lease-probe
.build/app-instance-lease-probe
