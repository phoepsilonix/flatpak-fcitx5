#!/bin/bash

cleanup() {
    pkill -P $$ || true
}

trap cleanup EXIT

SCRIPT_PATH="$(realpath "${BASH_SOURCE[-1]}")"
SCRIPT_DIRECTORY="$(dirname "$SCRIPT_PATH")"

set -e

# TMPDIR
[[ -z $TMPDIR ]] && TMPDIR=/tmp
BASE="$TMPDIR/update_mozc"

mkdir -p "$BASE"

cd "$BASE"
if [ ! -d mozc ]; then
    git clone --filter=tree:0 https://github.com/fcitx/mozc/
fi
[[ ! -d bcr ]] && git clone --filter=tree:0 https://github.com/bazelbuild/bazel-central-registry bcr
cd bcr
git fetch --all
git checkout origin/main
cd ..

cd mozc/src/
git fetch --all
git checkout origin/fcitx
git submodule update --init

_MOZC_BAZEL_CACHE="$BASE/mozc_cache"
_DOWNLOADER_CACHE="$BASE/downloader_cache"
BAZEL_MIRROR="$SCRIPT_DIRECTORY/bazel_mirror.py"

pushd .
mkdir -p "$_DOWNLOADER_CACHE"
cd "$_DOWNLOADER_CACHE"
python3 "$BAZEL_MIRROR" &
PROXY_PID=$!
popd
[[ -z $PROXY_PID ]] && exit 1

BUILD_TARGET="unix/fcitx5:fcitx5-mozc.so server:mozc_server gui/tool:mozc_tool"

build_native() {
    echo bazel build --nobuild --experimental_downloader_config="$SCRIPT_DIRECTORY/downloader.cfg" --registry=file://$BASE/bcr --experimental_repository_resolved_file=$BASE/resolved.bzl --repository_cache="$_MOZC_BAZEL_CACHE" --config oss_linux --config release_build $BUILD_TARGET
    bazel clean --expunge
    bazel build --nobuild --experimental_downloader_config="$SCRIPT_DIRECTORY/downloader.cfg" --registry=file://$BASE/bcr --experimental_repository_resolved_file=$BASE/resolved.bzl --repository_cache="$_MOZC_BAZEL_CACHE" --config oss_linux --config release_build $BUILD_TARGET
}

build_x86_64() {
    # x86_64 flatpak
    flatpak run --arch=x86_64 --command=sh \
        --env=BASE="$BASE" \
        --env=TMPDIR="$TMPDIR" \
        --env=PKG_CONFIG_PATH=/app/lib/pkgconfig \
        --env=SCRIPT_DIRECTORY="$SCRIPT_DIRECTORY" \
        --env=_MOZC_BAZEL_CACHE="$_MOZC_BAZEL_CACHE" \
        --env=BUILD_TARGET="$BUILD_TARGET" \
        --share=network --filesystem=xdg-cache \
        --filesystem="$SCRIPT_DIRECTORY" --filesystem="$TMPDIR" \
        --runtime=org.kde.Sdk/x86_64/6.6 org.fcitx.Fcitx5/x86_64/stable \
        -c "\
            PATH=$PATH:/usr/lib/sdk/bazel/bin:/usr/lib/sdk/llvm18/bin ; \
            CC=clang ; CXX=clang++ ; clang --version ; bazel --version ;\
            bazel clean --expunge ; \
            bazel build --nobuild --experimental_downloader_config="\$SCRIPT_DIRECTORY/downloader.cfg" \
            --registry=file://\$BASE/bcr \
	    --experimental_repository_resolved_file=\$BASE/resolved.bzl \
            --repository_cache="\$_MOZC_BAZEL_CACHE" \
            --config oss_linux --config release_build \${BUILD_TARGET}
        "
}

build_aarch64() {
    # aarch64 emulation flatpak with qemu-user-static-binfmt
    flatpak run --arch=aarch64 --command=sh \
        --env=BASE="$BASE" \
        --env=TMPDIR="$TMPDIR" \
        --env=PKG_CONFIG_PATH=/app/lib/pkgconfig \
        --env=SCRIPT_DIRECTORY="$SCRIPT_DIRECTORY" \
        --env=_MOZC_BAZEL_CACHE="$_MOZC_BAZEL_CACHE" \
        --env=BUILD_TARGET="$BUILD_TARGET" \
        --share=network --filesystem=xdg-cache \
        --filesystem="$SCRIPT_DIRECTORY" --filesystem="$TMPDIR" \
        --runtime=org.kde.Sdk/aarch64/6.6 org.fcitx.Fcitx5/aarch64/stable \
        -c "\
            PATH=$PATH:/usr/lib/sdk/bazel/bin:/usr/lib/sdk/llvm18/bin ; \
            CC=clang ; CXX=clang++ ; clang --version ; bazel --version ;\
            bazel clean --expunge ; \
            bazel build --nobuild --experimental_downloader_config="\$SCRIPT_DIRECTORY/downloader.cfg" \
            --registry=file://\$BASE/bcr \
	    --experimental_repository_resolved_file=\$BASE/resolved.bzl \
            --repository_cache="\$_MOZC_BAZEL_CACHE" \
            --config oss_linux --config release_build \${BUILD_TARGET}
        "
}

if [ "$1" = "aarch64" ]; then
    build_aarch64
elif [ "$1" = "x86_64" ]; then
    build_x86_64
elif [ "$1" = "multi_arch" ]; then
    build_native
    build_aarch64
elif [ "$1" = "flatpak" ]; then
    build_x86_64
    build_aarch64
else
    build_native
fi

kill $PROXY_PID
sed -e 's/^resolved = //' -e 's/ False/ "False"/g' -e 's/ None/ "None"/g' $BASE/resolved.bzl > $BASE/resolved.json
jq -r '[ .[] | select(.repositories != null) | .repositories[] | select(.attributes.name != null) | select(.rule_class != null) | { url: ( if .attributes.url == "" then ( .attributes.urls[0] // "") else (.attributes.url // (.attributes.urls[0] // "")) end ), sha256: ( .attributes.sha256 // "" ), downloaded_file_path: ( .attributes.downloaded_file_path // null ), } | select(.url != "") | { type: "file", url: .url, dest: "bazel-deps", } + ( if .downloaded_file_path != "" and .downloaded_file_path != null then { "dest-filename": .downloaded_file_path, } else {} end ) + { sha256: .sha256, } ]' $BASE/resolved.json > $BASE/mozc-deps.json

pushd .
cd $_DOWNLOADER_CACHE
for f in `find -type f` ; do
    if [[ ! "$f" =~ "./bcr.bazel.build/" ]];then
        url="https://${f#*/}"
        echo "- type: file"
        echo "  url: $url"
        echo "  dest: bazel-deps"
        sha=`sha256sum $f|cut -f1 -d" "`
        echo "  sha256: $sha"
	dest=$(jq -r '.[]|select(.url=="'$url'")|."dest-filename"' $BASE/mozc-deps.json)
	if [[ "$dest" != "null" ]];then
	    filename=$(basename $url)
	    [[ "$dest" != "$filename" ]] && echo "  dest-filename: $dest"
	fi
    fi
done > $SCRIPT_DIRECTORY/mozc-deps.yaml
popd

# add only-arches for cpython x86_64 and aarch64
yq -i -y '.[]|=
  .url as $url |
  if ($url | split("/")[-1] | contains("cpython") and contains("x86_64")) then
    . += {"only-arches": ["x86_64"]}
  elif ($url | split("/")[-1] | contains("cpython") and contains("aarch64")) then
    . += {"only-arches": ["aarch64"]}
  else
    .
  end
' "$SCRIPT_DIRECTORY/mozc-deps.yaml"

yq -y -i 'sort_by(.url)' "$SCRIPT_DIRECTORY/mozc-deps.yaml"

$SCRIPT_DIRECTORY/update_mozc_zip_code_patch

#rm -rf "$BASE"

exit 0