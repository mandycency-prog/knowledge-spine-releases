#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
baseline_app="${1:?Provide the verified backup of the installed app}"
release_parent="${2:?Provide a new release output directory}"
[[ "$baseline_app" == "$project_dir/.build/software-delivery-"* && -f "$baseline_app/Contents/Resources/Backend/local_pipeline.py" ]] || { print -u2 "Invalid baseline"; exit 1; }
[[ "$release_parent" == "$project_dir/dist/"* && ! -e "$release_parent" ]] || { print -u2 "Output must be a new dist directory"; exit 1; }
app_dir="$release_parent/直播与课程知识骨架.app"
build_dir="$project_dir/.build/arm64-apple-macosx/release"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/KnowledgeSpineApp" "$app_dir/Contents/MacOS/KnowledgeSpineApp"
cp "$build_dir/KnowledgeSpineAppleSpeech" "$app_dir/Contents/MacOS/KnowledgeSpineAppleSpeech"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"
# Retain the complete installed backend as one versioned unit. No selective
# cherry-picking of unaccepted model protocols into a software-only release.
ditto "$baseline_app/Contents/Resources" "$app_dir/Contents/Resources"
plutil -replace CFBundleShortVersionString -string 0.2.0 "$app_dir/Contents/Info.plist"
plutil -replace CFBundleVersion -string 20260912.1 "$app_dir/Contents/Info.plist"
plutil -insert KnowledgeSpineAnnotationAnalysisEnabled -bool NO "$app_dir/Contents/Info.plist"
plutil -insert KnowledgeSpineReleaseScope -string software-only "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier com.local.knowledgespine.apple-speech \
  --requirements '=designated => identifier "com.local.knowledgespine.apple-speech"' "$app_dir/Contents/MacOS/KnowledgeSpineAppleSpeech"
codesign --force --sign - --requirements '=designated => identifier "com.local.knowledgespine"' "$app_dir"
codesign --verify --deep --strict "$app_dir"
diff -qr "$baseline_app/Contents/Resources/Backend" "$app_dir/Contents/Resources/Backend"
print "$app_dir"
