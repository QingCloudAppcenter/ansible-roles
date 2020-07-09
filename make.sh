#!/usr/bin/env bash

set -eo pipefail

main() {
  if [ "$GITHUB_EVENT_NAME" == "pull_request" ];then
    log "checking ..."
    check
  elif [ "$GITHUB_EVENT_NAME" == "push" ];then
    log "building ..."
    build
    log "publishing new role packages ..."
    deploy
  fi
}

build() {
  # build changed packages
  local changedPackage; for changedPackage in $(findChangedPackageNames); do
    log "creating package $changedPackage ..."
    tar czf $changedPackage -C ${changedPackage%-*} .
  done
}

check() {
  log "ensuring only one role is changed in one PR ..."
  local changedPackages; changedPackages="$(findChangedPackageNames)"
  local changedCount=$(echo $changedPackages | wc -w)
  if [ "$changedCount" -gt 1 ]; then
    fatal 1 "Only one package is allowed to update at a time, though found $changedCount changed packages: [${changedPackages// /, }]."
  fi
}

deploy() {
  # switch to gh-pages branch
  git fetch
  git checkout -t origin/gh-pages

  log "preparing git author info ..."
  git config --global user.name "github-actions[bot]"
  git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

  log "preparing git commit ..."
  echo "roles:" > index.yml
  findPackages | sort | sed 's/^/- /g' >> index.yml
  git add *.tar.gz index.yml
  git diff --staged --quiet || git commit -m "update"

  log "pushing changes if any ..."
  git push
}

findChangedPackageNames() {
  comm -13 <(findPublishedPackageNames | sort) <(findPendingPackageNames | sort) | xargs
}

findPublishedPackageNames() {
  log "retrieving published packages ..."
  local owner=${GITHUB_REPOSITORY%%/*}
  local repo=${GITHUB_REPOSITORY##*/}
  local url=https://$owner.github.io/$repo/index.yml
  curl -sL $url | awk '$1=="-" {print $2}'
}

findPendingPackageNames() {
  local role version; for role in $(findRoles); do
    version="$(awk '$1=="role_version:" {print $2}' $role/meta/main.yml | grep ^[0-9])" || fatal 1 "version is required: $role."
    echo ${role}-${version}.tar.gz
  done
}

findRoles() {
   find . -mindepth 1 -maxdepth 1 -type d ! -name ".*" -printf "%f\n"
}

findPackages() {
   find . -mindepth 1 -maxdepth 1 -type f -name "*.tar.gz" -printf "%f\n"
}

fatal() {
  log ${@:2}
  return $1
}

log() {
  echo "$@" 1>&2
}

main
