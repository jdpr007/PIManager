# PI Manager — Iron-Clad Rules

These rules are NON-NEGOTIABLE and must be adhered to for any work done on this
project, in every session. They override convenience, brevity, or any other
consideration. If a change would violate one of these, the change does not ship.

1. **WoW 12.0.5 compatibility.** All API calls MUST be compatible with WoW
   version 12.0.5 (Midnight).

2. **Latest APIs only.** The addon must use the latest and most recent raw frame
   API calls, templates, and Lua code available for WoW 12.0.5 — the most
   updated of everything possible.

3. **No deprecated anything.** Do not use any deprecated APIs, templates,
   events, globals, or patterns. If a call has a modern namespaced replacement
   (e.g. `C_Spell.*`, `C_Item.*`, `C_Container.*`), use the modern one.

4. **40-player scale.** Must be fully optimized to handle large parties/raids of
   up to 40 players. No per-frame OnUpdate scans, no per-event allocations,
   pre-allocated scratch tables, single-pass O(n) roster scans, row-frame pool
   created once and reused.

5. **Debug option.** Include a debug option to help diagnose issues
   (`/pi debug on|off`, `/pi diag`).

6. **Login alert.** The addon must alert on login that it is loaded, and state
   the key command to open it (`/pi`).

7. **Verify against Blizzard source.** All APIs must be verified against
   Blizzard's wow-ui-source GitHub:
   https://github.com/Gethe/wow-ui-source/tree/live/Interface/AddOns/Blizzard_APIDocumentationGenerated

---

## Standing architectural decisions (derived from the rules + hard-won debugging)

- **No addon-owned SecureActionButton / Bindings.xml.** PI is cast from a normal
  Blizzard macro the user drags to their action bar. Reason: an addon-owned
  secure button taints the spellcast event chain, which silently blocks
  `C_ChatInfo.SendChatMessage`. (Rule 1/3.)

- **No `pcall(function() ... end)` wrapper around the OnEvent handler.** A closure
  created by tainted addon code is itself tainted; executing it taints the whole
  execution path and blocks protected chat sends. The event handler runs its
  body directly (the PowerWords-proven pattern). pcall is fine in non-secure
  paths like `ToggleWindow` and `ReattachMinimapButton`.

- **Chat sends fire from `UNIT_SPELLCAST_SUCCEEDED`**, using the target name
  captured from `UNIT_SPELLCAST_SENT` (keyed by castGUID), normalized with
  `Ambiguate(name, "none")`, sent via `C_ChatInfo.SendChatMessage`.

- **Midnight secret values:** guard cooldown/range comparisons with
  `issecretvalue` before any `<`, `>`, `==` on values from `C_Spell.*`.

- **Combat safety:** all macro/`EditMacro` writes gated by `InCombatLockdown()`
  and deferred to `PLAYER_REGEN_ENABLED` if blocked.

- **Never trust `GetMacroIndexByName` for create-or-update decisions.** It
  finds only the FIRST same-named macro and can return 0 during early load
  before the macro cache populates - this caused duplicate "PIManager" macros
  to be created on every login. Instead: (1) gate all macro creation behind a
  `MacroSystemReady()` check (`GetNumMacros()` returns two numbers when the
  cache is live), (2) scan ALL slots with `GetNumMacros`+`GetMacroInfo`
  (`ScanPIManagerMacros`) to COUNT same-named macros, (3) only `CreateMacro`
  when the count is exactly 0, (4) if duplicates exist, warn the player once
  and refuse to create more. Macro creation runs at first
  `PLAYER_ENTERING_WORLD` (cache reliably populated), NOT `PLAYER_LOGIN`.
  The addon NEVER auto-deletes macros - duplicate cleanup is a player action
  (delete extras in `/macro`, then `/reload` or `/pi macro`).

- **Dual minimap entry:** LibDBIcon button + AddonCompartmentFrame, so the
  launcher survives minimap-button-collector addons (Leatrix Plus, etc.).

## Known platform limitations (NOT addon bugs — do not chase these as code bugs)

- **Cross-realm whispers from inside instances** are unreliable at Blizzard's
  end; coalesced-realm names resolve as `Name (*)` which is not deliverable.
- **Cross-faction whispers** are blocked by the server entirely (except
  mercenary/cross-faction-group edge cases).
- **SAY / YELL / CHANNEL** require a hardware event and will be blocked when sent
  from an event handler. Use Party/Raid (`INSTANCE_CHAT`) for reliable in-dungeon
  notifications.
