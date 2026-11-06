#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_app="${1:?Provide the candidate app path}"
fixture="${2:?Provide the synthetic fixture database path}"
[[ "$source_app" == "$project_dir/dist/"* && -f "$source_app/Contents/Info.plist" ]] || exit 1
[[ "$fixture" == "$project_dir/.build/ui-fixture-"* && -f "$fixture" ]] || exit 1
test_root=$(mktemp -d /private/tmp/KnowledgeSpine-Acceptance-20260912-XXXXXX)
app_parent=$(mktemp -d "$project_dir/.build/software-ui-XXXXXX")
app_dir="$app_parent/知识骨架验收.app"
cp "$fixture" "$test_root/database.json"
ditto "$source_app" "$app_dir"
cp "$project_dir/Tests/AcceptanceInfo.plist" "$app_dir/Contents/Info.plist"
plutil -insert KnowledgeSpineAcceptanceRoot -string "$test_root" "$app_dir/Contents/Info.plist"
plutil -insert KnowledgeSpineAnnotationAnalysisEnabled -bool NO "$app_dir/Contents/Info.plist"
codesign --force --sign - --requirements '=designated => identifier "com.local.knowledgespine.acceptance"' "$app_dir"
codesign --verify --deep --strict "$app_dir"
print "APP=$app_dir"
print "DATA=$test_root"
