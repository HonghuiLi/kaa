#!/bin/sh
#
# Copyright 2014-2016 CyberVision, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# limitations under the License.
# See the License for the specific language governing permissions and

set -e

# Configs for deploy option
gh_pages=gh-pages
DOCS_ROOT=docs
GENERATED_DIR=doc
NEW_GENERATED_DIR=autogen-docs

# Color printing settings
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m' # No Color
COLOR_GREEN='\033[0;32m'
COLOR_ORANGE='\033[0;33m'

echo_green () {
  echo "${COLOR_GREEN} $1 ${COLOR_NC}"
}

echo_red () {
  echo "${COLOR_RED} $1 ${COLOR_NC}"
}

echo_orange () {
 echo "${COLOR_ORANGE} $1 ${COLOR_NC}"
}

# Different

# Helper
update_subtree () {
  if [ x"$gh_pages" = x"$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)" ]; then
    if [ -d "$1" ]; then
      git subtree merge --prefix="$1" "$2" -m "$3"
      echo "merged $2 in $1"
    else
      git subtree add --prefix="$1" "$2" -m "$3"
      echo "added $2 in $1"
    fi
  fi
}

# Removes nojekyll file if finds it
handle_nojekyll_file() {
  if [ -f .nojekyll ]; then
     echo_orange "Removing .nojekyll file"
     rm .nojekyll
     git commit .nojekyll -m "Removed .nojekyll file"
  fi
}

# If find path doc/client-c/0.10.0 moves it to autogen-docs/client-c/v0.10.0
handle_old_autogenerated_docs() {
  if [ -d $GENERATED_DIR ]; then
    echo_orange "Looks like previous documentation is here. Moving it to the new folder"
    mv -v $GENERATED_DIR $NEW_GENERATED_DIR
    rm -rf $GENERATED_DIR
    wrong_named_folders=$(find $NEW_GENERATED_DIR/*/* -prune -regex ".+/.+/[0-9|\.]+")
    if [ x"" != x"$wrong_named_folders" ]; then
      echo_orange "Changing folder names"
      for folder in $wrong_named_folders; do
        new_folder_name=$(echo $folder | sed -r 's/[0-9|\.]+/v\0/')
        mv -v $folder $new_folder_name
      done
    fi
    rm -rf $(find $NEW_GENERATED_DIR/*/* -prune -regex '.+/.+/latest')
    git add $GENERATED_DIR $NEW_GENERATED_DIR
    git commit -m "Moved old docs to $NEW_GENERATED_DIR"
  fi
}

get_subtree () {
  git add -f $1 >> /dev/null
  git commit -m "Added $1 version $2" >> /dev/null
  hash=$(git subtree split --prefix=$1)
  echo $hash
}

# For each version(tag) generates data (swagger.json), doxygen, etc. commits it
# and merges into gh-pages branch.
gather_docs_from_all_verions() {
  versions=$(git tag)
  echo_green "Gathering docs from all versions"
  for version in $versions; do
    if [ x"" != x"$(echo "$version" | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$")" ]; then
      echo_green "Checking $version"
      git checkout "$version" --force
      if [ -d doc ]; then
        # Special thing to handle swagger json
        echo_green "Generating files for $version"
        git checkout --detach
        mvn compile || echo_orange "Maven failed, but whatever"
        release_doc=$(get_subtree doc $version)
        # Generate java docs
        echo_green "Generating javadocs"
        cd client/client-multi/ && mvn javadoc:javadoc ; cd -
        java_android_docs=$(get_subtree client/client-multi/client-java-android/target/site/apidocs/ $version)
        java_core_docs=$(get_subtree    client/client-multi/client-java-core/target/site/apidocs/ $version)
        java_core_desktop=$(get_subtree client/client-multi/client-java-desktop/target/site/apidocs/ $version)
        # Generate c and cpp docs
        echo_green "Generating doxygen docs"
        mvn -P compile-client-cpp compile || echo_orange "Maven failed, but whatever"
        mkdir client/client-multi/client-c/target/apidocs && mvn -P compile-client-c compile || echo_orange "Maven failed, but whatever"
        c_doxygen=$(get_subtree client/client-multi/client-c/target/apidocs/doxygen $version)
        cpp_doxygen=$(get_subtree client/client-multi/client-cpp/target/apidocs/doxygen $version)
        git checkout $gh_pages --force
        update_subtree "$DOCS_ROOT/$version" "$release_doc" "Merged $version docs in the $gh_pages"
        update_subtree "$NEW_GENERATED_DIR/client-cpp/$version" "$cpp_doxygen" "Merged $version c++ client docs in the $gh_pages"
        update_subtree "$NEW_GENERATED_DIR/client-c/$version" "$c_doxygen" "Merged $version c client docs in the $gh_pages"
        update_subtree "$NEW_GENERATED_DIR/client-java-core/$version"    "$java_core_docs"    "Merged $version java-core docs in the $gh_pages"
        update_subtree "$NEW_GENERATED_DIR/client-java-desktop/$version" "$java_core_desktop" "Merged $version java-desktop docs in the $gh_pages"
        update_subtree "$NEW_GENERATED_DIR/client-java-android/$version" "$java_android_docs" "Merged $version java-android docs in the $gh_pages"
      fi
    fi
  done
  git checkout $gh_pages --force
}

# Generates data required for proper site build. $1 should be latest version
generate_jekyll_data() {
  mkdir -p _data
  echo_green "Generating config data"
  printf "%s\nversion: %s \ndocs_root: %s" "---" "$1" "$DOCS_ROOT" > _data/generated_config.yml
  echo_green "Generating menu data"
  ruby _scripts/create_global_toc.rb
  ruby _scripts/generate_latest_structure.rb
}

# Commits generated data
commit_jekyll_data() {
  git add _data/*
  git commit -m "Updated global toc and version"
  git add $DOCS_ROOT/latest/*
  git commit -m "Updated latest"
}

# Merges files frm $1 (should be latest version tag) into gh-pages branch
update_jekyll_structure() {
  git checkout "$1"
  if [ -d gh-pages-stub ]; then
    echo_green "Getting Jekyll files from version : $1"
  else
    echo_red "No gh-pages-stub dir in $1"
    exit 1
  fi
  branch_available=$(git branch --list $gh_pages)
  GH_PAGES_STUB=$(git subtree split --prefix=gh-pages-stub/)
  if [ x"" =  x"$branch_available" ]; then
    git checkout "origin/$gh_pages" -b "$gh_pages"
  else
    git checkout "$gh_pages"
  fi
  echo_green "Merging gh-pages-stub from $1"
  git merge "$GH_PAGES_STUB" -m "Merged jekyll files"
}

# Deploy . Main purpose of this script is to create dir structure where jekyll files is in root dir
# all docs is in $DOCS_ROOT/version and autogenerated docs is in $NEW_GENERATED_DIR . For
# generated dir structure menu generating script is called, config is generated and all results are commited.
deploy_docs () {
  echo_green "Generating full docs (it may take a while)"
  versions=$(git tag)
  echo_green "Looking for latest version"
  latest=$(git tag | sort -V -r | head -1)
  echo_green "Found latest version: $latest"
  update_jekyll_structure "$latest"
  handle_nojekyll_file
  handle_old_autogenerated_docs
  gather_docs_from_all_verions
  generate_jekyll_data "$latest"
  commit_jekyll_data
  echo_green "Finished deploy into gh-pages"
  echo_green "From this point there is few options to deploy this docs :"
  echo_green "\t 1. Push this branch into your github gh-pages branch and docs will be avaliable at YOUR_NAME.github.io/PROJECT_NAME"
  echo_green "\t 2. Create a pull request to update the main repository"
  echo_green "\t 3. Run \`jekyll serve\` to preview it locally"
}

# Test docs
test_docs() {
  curr_tag=$(git tag --contains)
  if [ x"$curr_tag" = x ]; then
    curr_tag="current"
  fi
  echo_green "Test deploy for $curr_tag"
  jekyll_root=test-gh-pages-$curr_tag
  latest=$curr_tag
  if [ ! -d $jekyll_root ]; then
    echo_green "Generating directory structure"
    mkdir -p $jekyll_root
    cp -R gh-pages-stub/* $jekyll_root
    mkdir -p $jekyll_root/$DOCS_ROOT
    ln -s "$PWD/doc" "$PWD/$jekyll_root/$DOCS_ROOT/$curr_tag"
  fi
  cd $jekyll_root
  generate_jekyll_data "$latest"
  echo_green "Serving the site"
  jekyll serve "$@"
}

# Main

if [ x"deploy" = x"$1" ]; then
  deploy_docs
elif [ -d doc ]; then
  test_docs
else
  echo "Nothing to do"
fi
