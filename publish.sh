#!/bin/bash

get_tag() {
    gh api repos/fcitx/$1/tags --jq .[].name --paginate | sort -r -V | head -n 1
}

get_commit() {
    gh api repos/fcitx/$1/commits/$2 --jq .sha
}

printarr() { declare -n __p="$1"; for k in "${!__p[@]}"; do printf "%s=%s\n" "$k" "${__p[$k]}" ; done ;  }

update_tag() {
    echo update_tag for $1
    for k in "${!repo_tag[@]}"; do
        local repo_info="${repo_tag[$k]}"
        if [[ "$repo_info" =~ ^tag: ]]; then
            yq -y -i '(.. |select(.sources?) | .sources[]? | select(.type? == "git" and .url? == "https://github.com/fcitx/'$k'")) .tag = "'${repo_info/tag:/}'"' $1
            yq -y -i '(.. |select(.sources?) | .sources[]? | select(.type? == "git" and .url? == "https://github.com/fcitx/'$k'")) |= del(.branch)' $1
        elif [[ "$repo_info" =~ ^commit: ]]; then
            yq -y -i '(.. |select(.sources?) | .sources[]? | select(.type? == "git" and .url? == "https://github.com/fcitx/'$k'")) .commit = "'${repo_info/commit:/}'"' $1
            yq -y -i '(.. |select(.sources?) | .sources[]? | select(.type? == "git" and .url? == "https://github.com/fcitx/'$k'")) |= del(.branch)' $1
        fi
    done
}

update_cherry_pick() {
    rm -f $GIT_REPO/cp-*.patch

    if [[ ! -f cherry-picks/$REPO ]]; then
        return
    fi

    for commit in `cat cherry-picks/$REPO`; do
        wget https://github.com/fcitx/$REPO/commit/$commit.patch -O $GIT_REPO/cp-$commit.patch
        yq -y -i '(.. |select(.modules?) | .modules[]? | select(.name? == "fcitx5")).sources += [{"type": "patch", "path": "'cp-$commit.patch'", "use-git": true}] ' $1
    done
}

populate_modules() {
    local basedir=$(dirname $1)
    for module in $(yq -r '.modules[]? | select(type == "string" and endswith(".yaml"))' $1); do
        local moduledir=$(dirname $module)
        mkdir -p $GIT_REPO/$basedir/$moduledir
        cp $basedir/$module $GIT_REPO/$basedir/$module
        update_tag $GIT_REPO/$basedir/$module
        populate_modules $basedir/$module
    done
}

if [[ "$1" == "" ]]; then
    echo "Need to provide a flatpak package name"
    exit 1
fi

declare -A repo_tag

REPO=
while read repo package option; do
    if [[ "$option" =~ ^branch: ]]; then
        repo_tag[$repo]=commit:$(get_commit $repo ${option/branch:/})
    else
        repo_tag[$repo]=tag:$(get_tag $repo)
    fi

    if [[ "$package" == "$1" ]]; then
        REPO=$repo
    fi
done < projects

PACKAGE=$1

GIT_REPO=$PACKAGE
if [[ "$2" == "new" ]]; then
    GIT_REPO=flathub
fi

printarr repo_tag

rm -rf $GIT_REPO
gh repo clone flathub/$GIT_REPO

if [[ "$2" == "new" ]]; then
    pushd .
    cd $GIT_REPO
    git checkout new-pr
    popd
fi

cp $PACKAGE.yaml $GIT_REPO/$PACKAGE.yaml

rm -rf $GIT_REPO/modules

populate_modules $PACKAGE.yaml

yq -y -i '.branch = "stable"' $GIT_REPO/$PACKAGE.yaml
if [[ "$PACKAGE" =~ .*Addon.* ]]; then
    cp flathub.json $GIT_REPO/
    yq -y -i '."runtime-version" = "stable"' $GIT_REPO/$PACKAGE.yaml
else
    yq -y -i '."add-extensions"."org.fcitx.Fcitx5.Addon".version = "stable"' $GIT_REPO/$PACKAGE.yaml
fi

if [[ $REPO == "mozc" ]]; then
    cp mozc-deps.yaml zip-code.patch $GIT_REPO/
fi

update_tag $GIT_REPO/$PACKAGE.yaml
update_cherry_pick $GIT_REPO/$PACKAGE.yaml

cd $GIT_REPO
LABEL=${repo_tag[$REPO]/:/-}
git add .
if [[ "$2" == "new" ]]; then
    git checkout -b $PACKAGE
    git commit -a -m "Add $PACKAGE"
fi

if [[ "$2" != "new" ]] && [[ "$2" != dry ]]; then
    git checkout -b pr-$LABEL
    git commit -a -m "Update $PACKAGE"
    git push origin --force pr-$LABEL
    gh pr create --base master --title "Update $LABEL" --body ""
fi
