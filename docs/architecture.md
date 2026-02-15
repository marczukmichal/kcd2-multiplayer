# Multiplayer Architecture

## Concept

KCD2 is not designed for multiplayer.
We simulate multiplayer by synchronizing player states externally.

## Data Flow

Player -> Lua -> Server -> Other clients

## Synced Data (v0.1)

- position (x,y,z)
- rotation
- animation id
- stance

## Ghost Players

Remote players are spawned as NPC placeholders:

- teleported each tick
- animation changed based on received state

## Authority

Server authoritative for:

- combat hits (future)

Clients authoritative for:

- movement (temporary)
