#!/bin/sh
# Xcode Cloud post-clone. The working directory starts in ci_scripts.
# Generates the Xcode project, writes Config/Secrets.xcconfig, and sets the
# build number above the TestFlight build that is already live (2).
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH}"

export HOMEBREW_NO_AUTO_UPDATE=1
brew install xcodegen
xcodegen generate
python3 scripts/write-secrets.py

# CI_BUILD_NUMBER starts at 1 for this workflow. Build 2 is already in
# TestFlight, so the first cloud archive is 3 and later archives climb.
build_number=$((CI_BUILD_NUMBER + 2))
sed -i '' "s/CURRENT_PROJECT_VERSION = 1;/CURRENT_PROJECT_VERSION = ${build_number};/g" JustUs.xcodeproj/project.pbxproj
echo "CURRENT_PROJECT_VERSION=${build_number}"
