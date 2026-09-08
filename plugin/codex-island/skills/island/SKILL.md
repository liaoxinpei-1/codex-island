---
name: island
description: Use when the user wants to open Codex Island, show or hide their MacBook Dynamic Island, open its settings or quick chat, or diagnose the island's Codex connection and pet assets. Does not replace the Codex client or its approval interface.
---

# Codex Island

Codex Island is a separately installed native macOS app (`local.codex-island.app`). It observes local Codex task state and opens original Codex conversations through deep links.

## Actions

Resolve `../../scripts/island.sh` relative to this skill directory. The helper accepts exactly:

- `show`: launch and expand the island.
- `hide`: collapse the island.
- `chat`: open the island's quick input.
- `settings`: open island settings.
- `status`: run the installed app's read-only diagnostic command; finishes in about 4 seconds.

Use the available native computer-use tool for UI interactions when its instructions require it; locate the app by bundle identifier and use its visible controls. The helper is also usable directly by the user from a terminal.

For status questions, run `bash <resolved-script> status` and report only relevant connection, live task, and pet counts. The diagnostic command does not send prompts, change Codex settings, or decide approvals.

## Boundaries

- The app reads the local Codex IPC snapshot protocol v11 and a read-only task catalog. Unsupported clients show a compatibility message; never edit the installed Codex app or its database to force compatibility.
- Built-in pet assets are read from the user's installed Codex. Local custom pets use `pet.json`; cloud-only pet assets are not fetched automatically.
- Complete conversations, voice and approval decisions remain in Codex. Do not claim this is a replacement implementation of Codex's entire pet interface.
- Do not reinstall, rebuild, kill other processes, or enable login startup unless the user's request calls for it.
- If the app is missing, state that the native companion must be installed; installing this plugin alone does not create the macOS overlay.
