#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe_dir=$(mktemp -d "$project_dir/.build/image-core-probe.XXXXXX")
swiftc -swift-version 6 -parse-as-library -module-cache-path "$project_dir/.build/image-core-probe-cache" \
  "$project_dir"/Sources/KnowledgeSpineCore/*.swift "$project_dir/Tests/ImageCoreProbe.swift" \
  -o "$probe_dir/ImageCoreProbe"
"$probe_dir/ImageCoreProbe"
