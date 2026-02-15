# CLAUDE PROJECT CONTEXT

This project is a multiplayer sandbox mod for Kingdom Come: Deliverance II.

IMPORTANT:

- The game is singleplayer only.
- Multiplayer is implemented as external synchronization layer.
- Other players are represented as ghost NPC entities.

## Architecture

Game Client (Lua mod)
-> sends player state
Server (Node.js / TS)
-> broadcasts states
Game Client
-> updates ghost NPCs

## Constraints

- No quest sync
- No savegame sync
- No inventory sync
- Focus on movement, animations and combat only.

## Game Environment

- Running inside KCD2 Modding Tools development build.
- Loose files are loaded directly.
- Internal debug API available at:
  http://localhost:1403

## Lua Mod

Entry point:
mod/data/scripts/mods/kcd2_mp.lua

Responsibilities:

- read player position
- read animation state
- send network packets
- receive remote players
- update ghost NPCs

## Server

Node.js + TypeScript.
Simple state relay server.

No game logic.

## Current Target (CRITICAL)

First milestone:
"I can see another player moving as NPC."

Do NOT implement complex systems before this milestone works.

## Coding Style

- Keep systems simple.
- Prefer explicit state objects.
- Log everything.
- Avoid abstraction until basic sync works.
