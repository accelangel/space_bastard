# Space Bastard Architecture Refactor - Implementation Guide

## Purpose of This Refactor

The current codebase has become an over-engineered mess with too many overlapping systems doing the same job. We have TargetData.gd, TargetManager.gd, AND SensorSystem.gd all trying to track targets - that's ridiculous redundancy. The PDC code is embarrassingly bad, shooting backwards because of broken lead time calculations. The architecture needs to be **severely simplified** without losing the core gameplay.

**Key Point**: The game should play exactly the same to the user, but the code architecture in Godot should be clean and maintainable.

## Core Philosophy Changes

### STOP ADDING POINTLESS COMPLEXITY
- **NO radar range limits** - radar sees the entire map, period
- **NO PDC bullet max lifetime** - bullets travel in space until they hit something or leave the map
- **NO damage systems yet** - torpedo hits PDC bullet = both despawn instantly
- **NO burst fire modes, ammunition tracking, or other unnecessary features**

### Battle Mechanics Reality
The complexity comes from realistic space combat physics, NOT from artificial software limitations. PDC bullets should travel across the entire battlefield if nothing stops them - that's just physics in space.

## What Gets Completely Deleted

### Files to Remove Entirely:
- `Scripts/Data/TargetData.gd` - Delete
- `Scripts/Managers/TargetManager.gd` - Delete  
- `Scripts/Managers/ShipManager.gd` - Delete (redundant with EntityManager)
- `Scripts/Entities/Ships/BaseShip.gd` - Delete

### Scene Structure Changes:
- Remove all turret graphics from PDC.tscn - PDC bullets spawn from ship center for now
- Simplify PDC to just a Node2D with script - no rotating barrels, no visual complexity
- PlayerShip and EnemyShip become separate, independent classes (no shared BaseShip)

## What Gets Kept (DO NOT REMOVE THESE)

### Torpedo Systems That Must Stay:
1. **PID guidance and intercept math** - IMPERATIVE, the torpedoes need sophisticated navigation
2. **Lateral launch system** - ESSENTIAL for clearing the launcher safely before main guidance kicks in
3. **All the complex torpedo guidance calculations** - These will be needed when torpedoes have to navigate through PDC fire fields

### Why These Stay:
The torpedoes will eventually need to maneuver through complex PDC bullet walls to reach their targets. The PID controllers and intercept math are what will make this possible. DO NOT SIMPLIFY THE TORPEDO GUIDANCE.

## New Architecture Overview

### Ship Classes (Separate, Not Inherited)

#### PlayerShip
- Extends Area2D (for collision detection)
- Has CollisionShape2D child node
- Will eventually have upgrade systems, progression mechanics, UI integration
- Faction: "friendly"

#### EnemyShip  
- Extends Area2D (for collision detection)
- Has CollisionShape2D child node
- Uses EnemyShipConfig resource for variety (different speeds, weapons, textures)
- Faction: "hostile"

#### EnemyShipConfig (Resource)
```gdscript
class_name EnemyShipConfig extends Resource
@export var max_speed: float
@export var pdc_fire_rate: float  
@export var torpedo_count: int
@export var ship_texture: Texture2D
```

### Weapon Systems

#### PDCSystem (Completely Rewritten)
**Current Problem**: The PDC code shoots backwards due to ridiculous lead time variables. It's "awful, so unsmart and childishly conceived."

**New Approach**: PDCs create bullet walls across torpedo flight paths. Instead of trying to predict where torpedoes will be in 2.5 seconds and shooting backwards, PDCs calculate where torpedoes are heading and create walls of bullets across those paths.

```gdscript
class_name PDCSystem extends Node2D

func _physics_process(delta):
    var torpedoes = sensor_system.get_all_enemy_torpedoes()
    for torpedo in torpedoes:
        if should_engage(torpedo):
            create_bullet_wall_across_path(torpedo)

func should_engage(torpedo: Node2D) -> bool:
    # Simple: if torpedo exists and is approaching, engage
    var to_torpedo = torpedo.global_position - global_position
    var torpedo_vel = torpedo.velocity if "velocity" in torpedo else Vector2.ZERO
    var approaching = torpedo_vel.dot(-to_torpedo.normalized()) > 0
    return approaching
```

#### PDCBullet (Actually Simple)
- Extends Area2D with CollisionShape2D
- Travels in straight line forever until collision or leaving map boundaries
- EntityManager auto-despawns bullets that leave map - no artificial lifetime limits
- Simple faction checking: "friendly" bullets kill "hostile" torpedoes

```gdscript
func _on_area_entered(area):
    if is_hostile_to(area):
        area.queue_free()  # Target dies instantly
        queue_free()       # Bullet dies too
```

### Torpedo System (Flexible for Future Variety)

#### Current Requirements:
- Keep all existing PID guidance and intercept math
- Keep lateral launch system (essential for safe deployment)
- Torpedoes do NOT dodge PDC bullets (they're not that smart yet)

#### Future Flexibility Needed:
The torpedo system must be architected to easily support:
- **Coordinated strikes**: 6 torpedoes launched in quick succession, all arriving simultaneously from different angles
- **Fragmenting torpedoes**: Break into smaller torpedoes when within PDC range
- **Different guidance types**: Ballistic, evasive, etc.

#### Solution: Resource-Based Torpedo Types
```gdscript
class_name TorpedoConfig extends Resource
@export var torpedo_name: String
@export var launch_pattern: LaunchPattern  # SINGLE, RAPID_SALVO, COORDINATED_STRIKE
@export var salvo_count: int
@export var approach_angles: Array[float]  # For coordinated strikes
@export var fragments_on_approach: bool
@export var fragment_count: int
```

Use inheritance hierarchy:
- **BaseTorpedo** - handles lateral launch, collision, common systems
- **StandardTorpedo** - current PID guidance (keep all existing math)
- **CoordinatedTorpedo** - calculates simultaneous arrival timing
- **FragmentingTorpedo** - breaks apart near target

### Core Systems

#### EntityManager (Simplified but Kept)
- Tracks all entities in the game
- Sends position reports to all SensorSystems (eliminates scanning lag)
- Auto-despawns anything that leaves map boundaries
- Handles spawning/despawning lifecycle

**Remove from EntityManager**:
- Complex targeting relationships
- Damage tracking  
- Custom data dictionaries
- Entity states beyond basic alive/dead

#### SensorSystem (Maximum Simplicity)
**One per ship. Configured by ship parameters.**

```gdscript
class_name SensorSystem extends Node2D

# NO RANGE LIMITS - radar sees entire map
var all_contacts: Array[Node2D] = []
var parent_ship: Node2D

func update_contacts(entities: Array[Node2D]):
    # Radar sees EVERYTHING on map - no distance calculations
    all_contacts = entities.filter(func(e): return is_enemy_of(e))
```

**Faction System**: Dead simple - everything is either "friendly" or "hostile" to everything else. Use string properties on entities:
- PlayerShip.faction = "friendly"  
- EnemyShip.faction = "hostile"
- PDC bullets inherit faction from launcher
- Torpedoes inherit faction from launcher

## Implementation Priority Order

### Phase 1: Core Architecture  
1. Delete TargetData.gd, TargetManager.gd, ShipManager.gd, BaseShip.gd
2. Create separate PlayerShip and EnemyShip classes (both extend Area2D)
3. Simplify EntityManager - remove complex features, keep entity tracking and auto-cleanup
4. Add simple faction system (string properties)

### Phase 2: Weapon Systems
1. Rewrite PDCSystem to create bullet walls instead of backwards shooting
2. Simplify PDCBullet to travel forever until collision
3. Set up torpedo inheritance hierarchy (BaseTorpedo -> StandardTorpedo)
4. Create TorpedoConfig resource system

### Phase 3: Integration & Testing
1. Ensure torpedoes still use PID guidance and lateral launch
2. Test PDC bullet walls vs torpedo navigation
3. Verify EntityManager auto-cleanup works
4. Confirm faction system prevents friendly fire

### Phase 4: Future Torpedo Types
1. Implement CoordinatedTorpedo for simultaneous strikes
2. Implement FragmentingTorpedo for cluster munitions
3. Create torpedo config resource files
4. Test torpedo variety through data-driven configs

## Critical Points to Remember

### DO NOT REMOVE:
- PID torpedo guidance and intercept calculations
- Lateral launch system
- Complex torpedo navigation math

### DO REMOVE:
- All radar range limitations
- PDC bullet lifetime limits  
- Damage systems (for now)
- Complex targeting relationships
- Confidence/data aging systems
- Ammunition tracking
- Burst fire modes

### The Goal:
Clean, maintainable architecture that preserves sophisticated torpedo behavior while eliminating all the unnecessary complexity. The player should notice no difference in gameplay - torpedoes should still fly intelligently at targets, PDCs should still shoot them down, but the code should be much cleaner and easier to extend.

**Remember**: Complex calculations every frame are inevitable with realistic space combat. That's why we need clean architecture - so we can focus on the physics and tactics, not debugging overlapping systems.