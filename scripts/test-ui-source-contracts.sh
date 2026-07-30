#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT_VIEW="$ROOT_DIR/Sources/App/Modules/Accounts/AccountsView.swift"
PROJECTS_VIEW="$ROOT_DIR/Sources/App/Modules/ProjectsAndTasks/ProjectsView.swift"
TOOLS_VIEW="$ROOT_DIR/Sources/App/Modules/ToolsAndAutomation/ToolsSkillsView.swift"
DESIGN_SYSTEM="$ROOT_DIR/Sources/App/SharedUI/DesignSystem.swift"
SHELL_VIEW="$ROOT_DIR/Sources/App/Shell/WorkbenchShell.swift"
ICON_SCRIPT="$ROOT_DIR/scripts/generate-app-icon.swift"
SETTINGS_VIEW="$ROOT_DIR/Sources/App/Modules/Appearance/WorkbenchPreferences.swift"
CAPTURE_SCRIPT="$ROOT_DIR/scripts/capture-visual-acceptance.sh"

required_patterns=(
  "import Charts"
  "LineMark"
  "AreaMark"
  "RuleMark"
  "chartXSelection"
  "localSnapshot"
  "account-usage-chart"
)

for pattern in "${required_patterns[@]}"; do
  if ! rg -q "$pattern" "$ACCOUNT_VIEW"; then
    echo "Missing account usage chart contract: $pattern" >&2
    exit 1
  fi
done

callout_patterns=(
  "ChartCalloutPlacement.place"
  "selected-day-detail"
  "TokenCountFormatter.accessibility"
  "usageInteractionOverlay"
)

for pattern in "${callout_patterns[@]}"; do
  if ! rg -q "$pattern" "$ACCOUNT_VIEW"; then
    echo "Missing bounded account usage callout contract: $pattern" >&2
    exit 1
  fi
done

if rg -q "\\.annotation\\(position: \\.top" "$ACCOUNT_VIEW"; then
  echo "Unbounded top chart annotation remains" >&2
  exit 1
fi

for view in "$ACCOUNT_VIEW" "$PROJECTS_VIEW" "$TOOLS_VIEW"; do
  for unit_pattern in "%.1fB" "%.1fM" "%.1fK"; do
    if rg -Fq "$unit_pattern" "$view"; then
      echo "English compact token formatter remains: $view ($unit_pattern)" >&2
      exit 1
    fi
  done
done

for view in "$PROJECTS_VIEW" "$TOOLS_VIEW"; do
  if ! rg -q "TokenCountFormatter.chinese" "$view"; then
    echo "Shared Chinese token formatter is missing: $view" >&2
    exit 1
  fi
done

if ! rg -q "WorkbenchLogoMark" "$DESIGN_SYSTEM" || rg -q 'Image\\(systemName: "scope"\\)' "$SHELL_VIEW"; then
  echo "Observation ring sidebar brand contract is missing" >&2
  exit 1
fi

for stale_icon_pattern in "halo" "innerOrbit" "timeline" "nodeYs"; do
  if rg -q "$stale_icon_pattern" "$ICON_SCRIPT"; then
    echo "Stale App icon geometry remains: $stale_icon_pattern" >&2
    exit 1
  fi
done

workflow_patterns=(
  "最近涉及的工具"
  "涉及任务"
  "工作流资产"
  "searchText"
  "mismatchedCopies"
)

for pattern in "${workflow_patterns[@]}"; do
  if ! rg -q "$pattern" "$TOOLS_VIEW"; then
    echo "Missing workflow asset UI contract: $pattern" >&2
    exit 1
  fi
done

for stale_pattern in "SkillRankingRow" "使用次数"; do
  if rg -q "$stale_pattern" "$TOOLS_VIEW"; then
    echo "Stale Skill usage UI remains: $stale_pattern" >&2
    exit 1
  fi
done

if ! rg -q "frame\\(width: 480, height: 420\\)" "$SETTINGS_VIEW"; then
  echo "Settings window height does not preserve all preference sections" >&2
  exit 1
fi

capture_patterns=(
  "screenshots/theme-usage-workflow-assets"
  "usage-900-light.png"
  "usage-1160-dark.png"
  "usage-1440-light.png"
  "usage-local-fallback"
  "assets-900-dark.png"
  "assets-1160-light.png"
  "assets-1440-dark.png"
)

for pattern in "${capture_patterns[@]}"; do
  if ! rg -q "$pattern" "$CAPTURE_SCRIPT"; then
    echo "Missing visual capture contract: $pattern" >&2
    exit 1
  fi
done

echo "PASS: account usage chart source contracts"
echo "PASS: workflow asset source contracts"
echo "PASS: theme usage asset capture contracts"
