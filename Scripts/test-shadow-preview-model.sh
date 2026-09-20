#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-shadow-ui-fixture.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Packages/ROBControlCore/Sources/ROBControlCore/Control/ROBShadowPlanningProtocol.swift" \
  "$repo_dir/Packages/ROBControlCore/Sources/ROBControlCore/Control/ROBShadowClutchGate.swift" \
  "$repo_dir/ROBControllerVision/Features/Control/ROBShadowPreviewModel.swift" \
  "$repo_dir/Tests/ROBShadowPreviewModelFixtureTests.swift" -o "$fixture_dir/model"
"$fixture_dir/model"
