# Eugene's Project Zomboid Mods

A collection of personal Project Zomboid Build 42 mods maintained by Eugene-17.

## Included mods

### Eugene's Army Bus Spawn

Spawns one fully repaired Autotsar Army Bus at `13705,1793,0` once per save with its plain, no-lettering skin and no roof rack. The bus has practical tools and supplies, one wooden crate, one student bench/table, no fuel, and a 100%-condition battery at 0% charge. It does not spawn skill books or a car battery charger; version 7 also removes those legacy items from an existing bus.

Dependency: Autotsar Tuning Atelier Bus. More Traits items are detected and added when available but are not required. Project RV Interior remains compatible but optional.

### Eugene's Money Skill Books

Adds hand-crafting recipes that use any radio as a reusable trading tool to exchange loose cash for individual skill books. Volume 1 costs $10; Volumes 2–5 cost $20, $30, $40, and $50 respectively and also consume the immediately previous volume. The radio can also sell electronics scrap for $1 each (with faster 10- and 50-item bulk trades), ordinary toys for $2 each, credit cards for $5 each, and tagged artifacts or mementos for $10 each. ID cards are excluded from memento sales. Trading awards no skill XP. Recipes are also provided for compatible skill books from the currently installed Extra Books, RadArchery, and Scavenging mods. An optional Gyde's Trait Magazines bridge prices each magazine at $20 per vanilla trait point, with a $50 minimum for zero-cost traits.

### Eugene's Random Animal Carriers

Adds balanced recipes for single-use animal carriers. Each carrier releases a randomized breed, sex, and life stage. Living animals can also be placed into portable bags without killing them.

Dependency: Cats Mod.

### Eugene's Constructible Fishing Pond

Provides two construction recipes: build a fishable pond center from two full 10 L buckets of water, or fill in a constructed center. Building a center automatically generates varied straight vanilla shoreline on its four cardinal sides without covering adjacent water; diagonal corner wedges are not used. Connected constructed water retains renewable fish schools, and Fishing 4 can inspect their stock directly.

### Eugene's More Traits Prowess Compatibility

Allows More Traits weapon-specialization traits to coexist, makes Ax-pert selectable, and increases the Packer Bag capacity from 50 to 150.

Dependencies: More Traits and Traits Purchase System.

### Eugene's Bone Meal

Adds Farming 3 recipes that grind 5 regular/large bones or 15 small bones into a five-use sack of bone meal. Each application advances a healthy crop by one stage with no watering requirement or per-plant cooldown; the empty sack is returned after the fifth use.

### Eugene's Prone Equipment

Right-click a nearby ordinary living zombie or another player while they are knocked down to change their worn clothing and wearable equipment. Bandit NPCs are explicitly excluded so their appearance, equipment, brain, and animation remain entirely under Bandits/True Companions control. Items put on a target must be loose in your inventory: they cannot already be worn, held in either hand, or attached to a hotbar slot. A zombie pacified by Eugene's Zombie Cure can also be secured as a 20 kg two-handed carrier. The carrier holds the embedded Simple Cure, the zombie's actual items, and a readable physical record of its appearance. It can pass through normal vehicle storage or an RV interior; setting it down creates a fresh pacified zombie from that record.

### Eugene's Zombie Cure

Adds three progressively stronger treatments. The Medical 3 Faulty Cure reanimates a human corpse as a hostile zombie. The Medical 6 Simple Cure removes player zombification without healing wounds, or restores and pacifies a prone ordinary zombie. On a zombie, the actual cure moves into its inventory and becomes the persistent pacification marker restored on load. Bandit NPCs are never valid cure targets. The Simple Cure awards 165 base Medical XP per craft, balanced so twelve doses with First Aid Volumes 4 and 5 take a character from Medical 6 to roughly Medical 10. The Medical 10 True Cure instantly replaces the pacified zombie with a same-sex friendly profile spawned and recruited by [B42] True Companions, copying only the zombie's restored appearance. The embedded Simple Cure is consumed, all physical belongings are dropped on the ground, and the survivor starts with an empty inventory. The survivor begins downed in True Companions' Help Up flow and starts on the Fond relationship tier. Legacy pacified zombies, carriers, and companions are migrated once to their current formats.

Dependencies: [B42] True Companions - Experimental and Eugene's Prone Equipment. True Companions supplies Bandits 2 transitively.

### Eugene's Auto Unwanted

Automatically marks newly looted clothing, tools, firearms, books (including recipe and writable literature), artifacts, and cooking utensils as Unwanted. Its six World Settings checkboxes default to enabled, and transfers between the player's own inventory containers are ignored.

Dependency: Organized Categories: Core.

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
