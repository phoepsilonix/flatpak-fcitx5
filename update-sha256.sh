#!/bin/bash

BASE=$PWD
pushd .

set -e

_MOZC_BAZEL_CACHE="${_MOZC_BAZEL_CACHE:-/tmp/mozc_cache}"

BAZEL_VER=$(bazel --version|cut -f2 -d" ")
if [[ "$BAZEL_VER">"7.1.2" ]];then
	bazel_flags=""
else
	bazel_flags="--noenable_bzlmod"
fi

bazel_flags+="
--verbose_failures
--sandbox_debug
"

_BUILD_TARGETS="${_BUILD_TARGETS:-unix/fcitx5:fcitx5-mozc.so server:mozc_server gui/tool:mozc_tool}"
cd mozc/src
bazel clean --expunge
bazel build --nobuild --experimental_repository_resolved_file=resolved.bzl --repository_cache="$_MOZC_BAZEL_CACHE" --config oss_linux --config release_build $_BUILD_TARGETS $bazel_flags "$@"

cp -a resolved.bzl $_MOZC_BAZEL_CACHE

pushd .
cd $_MOZC_BAZEL_CACHE
sed -e 's/^resolved = //' -e 's/ False/ "False"/g' -e 's/ None/ "None"/g' resolved.bzl > resolved.json

function UpdateSha256() {
	local url=$1
	local new_hash=$2
	jq '
	def update_sha256(update_url; new_hash):
	walk(
	if type == "object" and .attributes.url == update_url then
		.attributes.sha256 = new_hash
	elif type == "object" and .attributes.urls[0] == update_url then
		.attributes.sha256 = new_hash
	elif type == "object" and .attributes.urls[1] == update_url then
		.attributes.sha256 = new_hash
	else
		.
	end
	);

	update_sha256("'$url'" ; "'$new_hash'")
	' resolved.json > resolved.tmp
	cp -a resolved.tmp resolved.json
	sync
}

urls=$(jq -r -f $BASE/resolved.jq resolved.json |jq -r ".[]|.url")

for f in $(find $_MOZC_BAZEL_CACHE -name "id-*");
do
       files+="$(file $(dirname $f)/file)""\n"
done
zipfiles=$(echo -e $files|grep Zip|cut -f1 -d" "|sed "s/:$//")
for f in $zipfiles;
do
       zipfiles_info+="$(unzip -l $f)"
done
tarfiles=$(echo -e $files|grep -E "gzip|tar|xz|bzip"|cut -f1 -d" "|sed "s/:$//")
for f in $tarfiles;
do
	tarfiles_info+="$(echo $f) $(tar -tf $f)"
done

mkdir -p distdir
for url in $urls
do
       filename=$(basename $url)
       sha=$(jq -r -f $BASE/resolved.jq resolved.json | jq -r '.[]|select(.url=="'$url'")|.sha256')
       if [[ -z "$sha" ]]; then
               strip_name="${filename%"${filename##*[0-9]}"}"
               [[ -z $strip_name ]] && strip_name=${filename%.*}
               #[[ -n $strip_name ]] && strip_name=${strip_name%-*}
               if [[ -n $strip_name ]];then
                       sha=$(echo -e "$files"|grep "$strip_name"|cut -f1 -d" ")
                       if [[ -n "$sha" ]];then
                               sha=$(basename $(dirname $sha))
                       else
			       sha=$(echo -e "$zipfiles_info"|grep -i -B3 $strip_name || true)
			       sha=$(echo -e $sha|awk '{FS=" "}{print $4}')
			       if [[ -z "$sha" ]];then
				       sha=$(echo -e "$tarfiles_info"|grep -i $strip_name || true)
				       sha=$(echo $sha |grep -o "content_addressable/sha256/[^ ]*"|head -n1)
				       if [[ -n "$sha" ]]; then
					       sha=${sha%/*}
					       sha=${sha##*/}
				       else
					       sha=""
				       fi
			       else
				       sha=$(basename $(dirname $sha))
			       fi
		       fi
	       else
		       sha=""
	       fi
       fi
       if [[ -z $sha ]];then
	       (cd distdir; wget -nc $url)
	       sha=$(sha256sum distdir/$filename|cut -f1 -d" ")
       fi
       [[ -n $sha ]] && UpdateSha256 $url $sha
       sha=""
done

cp resolved.json $BASE/
jq -r -f $BASE/resolved.jq $BASE/resolved.json > $BASE/mozc-deps.json
yq -y "." $BAZE/mozc-deps.json > $BASE/mozc-deps.yaml
popd

yq -y -i 'sort_by(.url)' $BASE/mozc-deps.yaml

#rm -rf $_MOZC_BAZEL_CACHE

popd
bash $BASE/update_mozc_zip_code_patch