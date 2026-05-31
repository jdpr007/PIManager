# PI Manager v1.6.2

Power Infusion manager for Shadow Priests. **Fully compatible with WoW 12.0.5 (Midnight).** Optimized for parties and raids up to 40 players.

## Install

Copy the `PIManager` folder to:

```
World of Warcraft/_retail_/Interface/AddOns/PIManager/
```

Then `/reload` or restart the game. On login the addon prints a confirmation, and it creates the `PIManager` macro once you've fully entered the world.

## How it works

PI Manager builds and maintains a normal Blizzard macro named **PIManager** in your macro book. Open `/macro`, drag it to any action bar slot, and bind that slot to whatever key you like. The addon keeps the macro body up to date automatically — you never edit it by hand.

The macro uses live target conditionals, so the actual recipient is resolved by the game at the moment you press it:

```
/cast [@<assigned>,help,nodead][@<fallback>,help,nodead][@player] Power Infusion
/use 13            (if Trinket 13 enabled and equipped)
/use 14            (if Trinket 14 enabled and equipped)
/use <bag> <slot>  (if a combat potion is enabled and found)
```

Cast priority: **assigned target → an eligible fallback group member → yourself** (so the cooldown is never wasted). After each cast the addon prints who Power Infusion landed on.

## Features

- Main GUI window — `/pi` to toggle, or left-click the minimap button
- Two launch points: a LibDBIcon minimap button (tooltip shows the current assignment) and an entry in Blizzard's AddonCompartment menu
- Status line in the window showing Power Infusion's cooldown (Ready / CD seconds) and who the next cast will target
- Player list with class colors and faction tags ([A] Alliance / [H] Horde)
- Auto-maintained Blizzard macro — drag from `/macro` to any action bar slot, bind however you like
- Cast confirmation: after each cast, prints who Power Infusion landed on (assigned / fallback / self)
- Trinket slot 13 / 14 toggles (only fire if the slot is equipped)
- Combat potion toggle, with a custom potion set by drag-and-drop or by item ID / name
- Debug + diagnostics output for troubleshooting

## Slash commands

| Command | Action |
|---|---|
| `/pi` | Toggle the window |
| `/pi hide` | Close the window |
| `/pi assign <name>` | Assign PI to a player |
| `/pi clear` | Clear the assignment |
| `/pi trinket1 [on\|off]` | Toggle/set Trinket slot 13 usage |
| `/pi trinket2 [on\|off]` | Toggle/set Trinket slot 14 usage |
| `/pi potion [on\|off]` | Toggle/set combat potion usage |
| `/pi setpotion <id\|name>` | Set custom potion by item ID or exact name |
| `/pi clearpotion` | Clear custom potion (revert to default list) |
| `/pi macro` | Create/update the Blizzard macro for action bars |
| `/pi fix` | Re-attach the minimap button if it stopped responding |
| `/pi diag` | Print full diagnostic info |
| `/pi debug [on\|off]` | Toggle/set debug logging |
| `/pi reset` | Wipe all saved settings |
| `/pi help` | Show the command list |

## Raid-safety design

Built to be quiet in 40-player raid content:

- **No `OnUpdate` polling.** Status line and target resolution refresh only on game events (roster changes, equipment changes, combat boundaries).
- **Pre-allocated scratch tables.** `FindCastTarget` reuses the same tables across calls — zero allocations per raid scan.
- **Single-pass O(n) raid scan.** One walk through the roster categorizes each member inline.
- **Row pool.** Player list rows are created once and reused; no `CreateFrame` churn during raid events.
- **No `SPELL_UPDATE_COOLDOWN`.** That high-frequency event is never registered.
- **Combat-safe macro updates.** `EditMacro`/`CreateMacro` are gated by `InCombatLockdown`; updates that hit during combat defer to `PLAYER_REGEN_ENABLED`.
- **Change-detected macro writes.** The macro body is only rewritten when its content actually changes.
- **Duplicate-safe macro creation.** The addon scans all macros before creating one, so it never spawns duplicate `PIManager` macros, and warns you if extras already exist.

## Files

```
PIManager/
├── PIManager.toc          Addon manifest (Interface 120005)
├── PIManager.lua          All addon code
├── README.md              This file
├── IRONCLAD_RULES.md      Development/design rules
└── libs/
    ├── LibStub/
    ├── CallbackHandler-1.0/
    ├── LibDataBroker-1.1/
    └── LibDBIcon-1.0/     For the minimap button
```

## Notes

A previous version included whisper/say/party "notify on cast" options. These were removed because the WoW server blocks/throttles addon-automated whispers (an anti-spam measure), so they could not be made reliable. See `IRONCLAD_RULES.md` for details.

## Coding disclosure

This project was entirely vibe coded using Claude Opus 4.8. The addon — including its target resolution, auto-maintained Blizzard macro, minimap button, player list UI, and documentation — was developed iteratively in conversation with the model rather than hand-written line by line.
