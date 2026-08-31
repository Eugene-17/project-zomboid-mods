# Eugene's Project Zomboid Mods

A collection of personal Project Zomboid Build 42 mods maintained by Eugene-17.

## Included mods

### Eugene's Army Bus Spawn

Spawns one fully repaired Autotsar Army Bus at `13705,1793,0` once per save. The bus has a curated clean inventory, nine wooden crates, two student bench/tables, no fuel, and a 100%-condition battery at 0% charge. It dynamically includes Volumes I-V of every standard leveling-book series loaded from the base game and enabled mods, while excluding recipe and trait-granting literature. PROJECT RV Interior terrain is left unchanged, so farmable dirt must be moved into the RV area manually.

Dependencies: Autotsar Tuning Atelier Bus, More Traits, and Project RV Interior. Compatible leveling books from optional mods such as Scavenging Skill, Extra Books, and RadArchery are included automatically when those mods are enabled.

### Eugene's Random Animal Carriers

Adds balanced recipes for single-use animal carriers. Each carrier releases a randomized breed, sex, and life stage. Living animals can also be placed into portable bags without killing them.

Dependency: Cats Mod.

### Eugene's Constructible Fishing Pond

Adds individually buildable pond center, edge, and corner tiles. A complete closed pond at least 3x3 in size creates a renewable fish school. It also includes craftable Fish Check Glasses for inspecting fish-school status.

### Eugene's More Traits Prowess Compatibility

Allows More Traits weapon-specialization traits to coexist, makes Ax-pert selectable, and increases the Packer Bag capacity from 50 to 150.

Dependencies: More Traits and Traits Purchase System.

### Eugene's Bone Meal

Adds Farming 3 bone-meal recipes. Applying one dose to a healthy, adequately watered crop advances it by one stage, with a 24-hour per-plant cooldown.

### Eugene's Prone Equipment

Right-click a nearby living zombie or another player while they are knocked down to change their worn clothing and wearable equipment. Items put on a target must be loose in your inventory: they cannot already be worn, held in either hand, or attached to a hotbar slot. A zombie pacified by Eugene's Zombie Cure can also be secured as a 20 kg two-handed carrier. The carrier holds the zombie's actual items and a readable physical record of its appearance. It can pass through normal vehicle storage or an RV interior; setting it down creates a fresh pacified zombie from that record.

### Eugene's Zombie Cure

Adds a two-stage endgame treatment. The Medical 6 Knox Infection Cure removes player zombification without healing wounds, or restores and pacifies a prone zombie. A pacified zombie left in the world is intentionally not tracked across save/load; secure it in the carrier when it must persist. It awards 165 base Medical XP per craft, balanced so twelve doses with First Aid Volumes 4 and 5 take a character from Medical 6 to roughly Medical 10. The more expensive Medical 10 Human Restoration Serum writes the same physical zombie record, transfers the actual items, and creates a named, permanent, loyal Bandits companion from them.

Dependency: Bandits 2.

## Installation

Copy the desired folder from `mods/` into your local Project Zomboid mod directory:

```text
%UserProfile%\Zomboid\mods
```

Enable the mod and its listed dependencies in Project Zomboid. Restart the game after installing or updating Lua files.

## Compatibility note

The internal IDs and folder names still begin with `Codex`. They are intentionally retained so existing saves and enabled-mod settings continue to recognize the mods. Only the player-visible names use the Eugene's branding.

## Game version

These mods target Project Zomboid Build 42.20 or newer.
