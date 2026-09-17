#!/bin/zsh
set -euo pipefail
setopt null_glob

script_dir=${0:A:h}
repo_root=${script_dir:h}
cd "$repo_root"

for path in Sources/**/*.swift(.N); do
    case "$path" in
        Sources/Providers/ClaudeProfile.swift|\
        Sources/Providers/ClaudeUsageCLI.swift|\
        Sources/Providers/CodexUsage.swift|\
        Sources/Providers/CursorUsage.swift|\
        Sources/Providers/GlyphOutline.swift|\
        Sources/Providers/ProviderAccount.swift|\
        Sources/Providers/ProviderGlyph.swift|\
        Sources/Providers/SQLiteStore.swift|\
        Sources/Providers/UsageProvider.swift)
            ;;
        Sources/Providers/*)
            continue
            ;;
        Sources/Model/Fixtures.swift|\
        Sources/Safe/SafeClaudeOAuthUsage.swift|\
        Sources/Sessions/AntigravityActivityMonitor.swift|\
        Sources/Sessions/GeminiCLIActivityMonitor.swift|\
        Sources/Sessions/GrokActivityMonitor.swift|\
        Sources/Settings/ReleaseNotes.swift|\
        Sources/Settings/WhatsNewView.swift|\
        Sources/Settings/WhatsNewWindowController.swift)
            continue
            ;;
    esac
    print -rn -- "$path"$'\0'
done
