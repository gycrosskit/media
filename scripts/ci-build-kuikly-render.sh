#!/usr/bin/env bash
# Build one pinned Renderer and optional component Module Pod, from source or an exact remote tag.
set -euo pipefail
build_dir=${1:?Usage: ci-build-kuikly-render.sh absolute-build-directory}
[[ "$build_dir" = /* ]] || { echo 'Build directory must be absolute' >&2; exit 1; }
module_pod=${2:-}
module_repository=${3:-}
module_tag=${4:-}
if [[ -n "$module_pod" ]]; then
  [[ "$module_pod" =~ ^[A-Za-z][A-Za-z0-9]*(/[A-Za-z][A-Za-z0-9]*)?$ ]] || { echo 'Invalid Module Pod name' >&2; exit 1; }
  if [[ -n "$module_repository$module_tag" ]]; then
    [[ "$module_repository" =~ ^[a-z][a-z0-9-]*$ && "$module_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid remote repository or immutable tag' >&2; exit 1; }
  else
    test -f "${module_pod%%/*}.podspec" || { echo 'Local Module Podspec is missing' >&2; exit 1; }
  fi
elif [[ -n "$module_repository$module_tag" ]]; then
  echo 'A Module Pod name is required for a remote source' >&2; exit 1
fi
export GYC_MODULE_POD="$module_pod" GYC_MODULE_REPOSITORY="$module_repository" GYC_MODULE_TAG="$module_tag" GYC_MODULE_SOURCE="$PWD"
case "$(uname -m)" in arm64|x86_64) native_arch=$(uname -m) ;; *) echo 'Unsupported macOS architecture' >&2; exit 1 ;; esac
mkdir -p "$build_dir"
framework_parent="$build_dir/Products"
cat > "$build_dir/Podfile" <<'POD'
install! 'cocoapods', :integrate_targets => false
platform :ios, '15.0'
use_frameworks!
target 'KuiklyRenderProbe' do
  pod 'OpenKuiklyIOSRender', '2.28.0'
  unless ENV.fetch('GYC_MODULE_POD').empty?
    source = if ENV.fetch('GYC_MODULE_TAG').empty?
      { :path => ENV.fetch('GYC_MODULE_SOURCE') }
    else
      { :git => "https://github.com/gycrosskit/#{ENV.fetch('GYC_MODULE_REPOSITORY')}.git", :tag => ENV.fetch('GYC_MODULE_TAG') }
    end
    pod ENV.fetch('GYC_MODULE_POD'), **source
  end
end
POD
(cd "$build_dir" && CP_HOME_DIR="$build_dir/cocoapods" pod install) >&2
native_scheme=${module_pod%%/*}
native_scheme=${native_scheme:-OpenKuiklyIOSRender}
xcodebuild -project "$build_dir/Pods/Pods.xcodeproj" -scheme "$native_scheme" \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath "$build_dir/DerivedData" -arch "$native_arch" \
  ONLY_ACTIVE_ARCH=YES CONFIGURATION_BUILD_DIR="$framework_parent" CODE_SIGNING_ALLOWED=NO build >&2
binary="$framework_parent/OpenKuiklyIOSRender.framework/OpenKuiklyIOSRender"
test -f "$binary"
lipo "$binary" -verify_arch "$native_arch"
nm -gU "$binary" | grep '_com_tencent_kuikly_IsCurrentOnContextThread$' >&2
if [[ -n "$module_pod" ]]; then
  module_binary="$framework_parent/$native_scheme.framework/$native_scheme"
  test -f "$module_binary"
  lipo "$module_binary" -verify_arch "$native_arch"
fi
printf '%s\n' "$framework_parent"
