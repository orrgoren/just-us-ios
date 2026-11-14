#!/usr/bin/env bash
set -euo pipefail
device="${1:-booted}"
fixture="${2:-Fixtures/apns/plan-ready.apns}"
xcrun simctl push "$device" "$fixture"
