# KCD2 Multiplayer Sandbox Mod

Goal:

- Shared world multiplayer for Kingdom Come: Deliverance II
- Player visibility (ghost players)
- Animation sync
- Basic combat sync
- No quests / no progression sync

## Project Structure

- /mod → Lua scripts loaded by KCD2 development build
- /server → Multiplayer state sync server
- /docs → Architecture + API notes for AI and developers
- CLAUDE.md → Context file for Claude Code

## Current Milestone

v0.1:

- Read player position
- Send state to server
- Spawn ghost NPC
