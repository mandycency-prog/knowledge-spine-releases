#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe_dir=$(mktemp -d "$project_dir/.build/portable-probe.XXXXXX")
swiftc -swift-version 6 -parse-as-library -module-cache-path "$project_dir/.build/portable-probe-cache" \
  "$project_dir"/Sources/KnowledgeSpineCore/*.swift "$project_dir/Tests/PortableMindMapProbe.swift" \
  -o "$probe_dir/PortableMindMapProbe"
"$probe_dir/PortableMindMapProbe"
