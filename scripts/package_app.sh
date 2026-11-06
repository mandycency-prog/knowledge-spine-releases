#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
sdk_path="$(xcrun --show-sdk-path)"
build_dir="$project_dir/.build"
package_path="$project_dir/dist/直播与课程知识骨架.app"
mkdir -p "$build_dir"
# Assemble only declared resources. Reusing the old bundle can sign stale
# Python bytecode, which is later invalidated by an ordinary application run.
stage_dir="$(mktemp -d "$build_dir/package-stage.XXXXXX")"
app_dir="$stage_dir/直播与课程知识骨架.app"

mkdir -p \
  "$build_dir/swift-cache" \
  "$build_dir/swiftpm-cache" \
  "$build_dir/swiftpm-config" \
  "$build_dir/swiftpm-security" \
  "$app_dir/Contents/MacOS" \
  "$app_dir/Contents/Resources/Backend"

SDKROOT="$sdk_path" \
SWIFT_MODULECACHE_PATH="$build_dir/swift-cache" \
CLANG_MODULE_CACHE_PATH="$build_dir/swift-cache" \
swift build \
  --configuration release \
  --disable-sandbox \
  --cache-path "$build_dir/swiftpm-cache" \
  --config-path "$build_dir/swiftpm-config" \
  --security-path "$build_dir/swiftpm-security" \
  --scratch-path "$build_dir" \
  --sdk "$sdk_path"

cp "$build_dir/arm64-apple-macosx/release/KnowledgeSpineApp" "$app_dir/Contents/MacOS/KnowledgeSpineApp"
cp "$build_dir/arm64-apple-macosx/release/KnowledgeSpineAppleSpeech" "$app_dir/Contents/MacOS/KnowledgeSpineAppleSpeech"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Backend/local_pipeline.py" "$app_dir/Contents/Resources/Backend/local_pipeline.py"
cp "$project_dir/Backend/quote_evidence.py" "$app_dir/Contents/Resources/Backend/quote_evidence.py"
cp "$project_dir/Backend/source_bound_map.py" "$app_dir/Contents/Resources/Backend/source_bound_map.py"
cp "$project_dir/Backend/stage_synthesis.py" "$app_dir/Contents/Resources/Backend/stage_synthesis.py"
cp "$project_dir/Backend/branch_expansion.py" "$app_dir/Contents/Resources/Backend/branch_expansion.py"
cp "$project_dir/Backend/focused_study.py" "$app_dir/Contents/Resources/Backend/focused_study.py"
cp "$project_dir/Backend/model_lease.py" "$app_dir/Contents/Resources/Backend/model_lease.py"
cp "$project_dir/Backend/remote_model.py" "$app_dir/Contents/Resources/Backend/remote_model.py"
cp "$project_dir/Backend/image_analysis.py" "$app_dir/Contents/Resources/Backend/image_analysis.py"
cp "$project_dir/Backend/transcript_proofreader.py" "$app_dir/Contents/Resources/Backend/transcript_proofreader.py"
cp "$project_dir/Backend/punctuation_formatter.py" "$app_dir/Contents/Resources/Backend/punctuation_formatter.py"
cp "$project_dir/Backend/live_worker.py" "$app_dir/Contents/Resources/Backend/live_worker.py"
cp "$project_dir/Backend/audio_context.py" "$app_dir/Contents/Resources/Backend/audio_context.py"
cp "$project_dir/Backend/apple_speech.py" "$app_dir/Contents/Resources/Backend/apple_speech.py"
chmod 755 "$app_dir/Contents/MacOS/KnowledgeSpineApp"
chmod 755 "$app_dir/Contents/MacOS/KnowledgeSpineAppleSpeech"
codesign --force --sign - --identifier com.local.knowledgespine.apple-speech \
  --requirements '=designated => identifier "com.local.knowledgespine.apple-speech"' \
  "$app_dir/Contents/MacOS/KnowledgeSpineAppleSpeech"
# Keep a stable designated requirement across local rebuilds. Without this,
# ad-hoc signing defaults to a changing CDHash and macOS TCC treats every
# rebuild as a different screen/system-audio permission requester.
codesign \
  --force \
  --sign - \
  --requirements '=designated => identifier "com.local.knowledgespine"' \
  "$app_dir"
codesign --verify --deep --strict "$app_dir"
mkdir -p "$project_dir/dist"
if [[ -e "$package_path" ]]; then
  previous_dir="$(mktemp -d "$build_dir/previous-package.XXXXXX")"
  mv "$package_path" "$previous_dir/直播与课程知识骨架.app"
fi
mv "$app_dir" "$package_path"
rmdir "$stage_dir"
echo "$package_path"
