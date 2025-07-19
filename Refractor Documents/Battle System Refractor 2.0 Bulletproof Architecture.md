Battle System Refactor 2.0: Bulletproof Architecture
Immediate State & Zero-Trust Design
Overview
The current system's fundamental flaw is temporal coupling - it assumes data remains valid across frames. This creates cascading failures from ID mismatches, freed nodes, and race conditions. This refactor embraces Godot's immediate-mode reality while maintaining sophisticated battle analytics.
Core Design Principles

Immediate State Over Persistent References

Never store node references across frames
Query current state when needed
Trust only what exists RIGHT NOW


Zero-Trust Validation

Every function validates its inputs
No assumptions about data validity
Fail gracefully with sensible defaults


Direct Node Relationships

Nodes carry their own identity
Relationships verified through node properties
No external ID mapping required


Event Recording Without Control

EntityManager observes but doesn't control
Systems work independently
Analytics derived from observations




Problem Analysis
Current Architecture Failures
1. The ID Generation Race
gdscript# PROBLEM: Multiple ID generation methods
FireControl: "torpedo_" + str(instance_id)  # Can be empty!
EntityManager: "torpedo_" + str(counter)     # Different ID!
Torpedo itself: No inherent ID              # Relies on external systems
Why it fails: Instance IDs can be invalid during destruction. Counter-based IDs lose sync. No single source of truth.
2. The Reference Lifetime Problem
gdscript# PROBLEM: Storing references across frames
var tracked_targets = {
    "torpedo_123": {
        "node_ref": torpedo_node,  # Might be freed next frame!
        "last_position": Vector2()
    }
}
Why it fails: Godot's queue_free() creates zombies. is_instance_valid() isn't always reliable. Nodes can be in "dying" state.
3. The Signal Chain Fragility
gdscript# PROBLEM: Signals firing during destruction
torpedo.tree_exiting.connect(_on_torpedo_destroyed)
# But torpedo might already be invalid when signal fires!
Why it fails: Signal order isn't guaranteed. Nodes might disconnect during destruction. Race conditions everywhere.

New Architecture: Immediate State System
Core Components
1. Self-Identifying Nodes
Every combat node carries its own complete identity:
gdscript# Torpedo.gd
extends Area2D
class_name Torpedo

# Identity baked into the node
@export var torpedo_id: String = ""
@export var birth_time: float = 0.0
@export var faction: String = "hostile"
@export var source_ship_id: String = ""

# State management
var is_alive: bool = true
var marked_for_death: bool = false

func _ready():
    # Generate ID if not provided
    if torpedo_id == "":
        torpedo_id = "torpedo_%d_%d" % [OS.get_ticks_msec(), get_instance_id()]
    
    birth_time = Time.get_ticks_msec() / 1000.0
    add_to_group("torpedoes")
    add_to_group("combat_entities")
    
    # Store all identity data as metadata for redundancy
    set_meta("torpedo_id", torpedo_id)
    set_meta("faction", faction)
    set_meta("entity_type", "torpedo")

func mark_for_destruction(reason: String):
    if marked_for_death:
        return  # Already dying
    
    marked_for_death = true
    is_alive = false
    
    # Disable immediately
    set_physics_process(false)
    if has_node("CollisionShape2D"):
        $CollisionShape2D.disabled = true
    
    # Notify observers
    get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
    
    # Safe cleanup
    queue_free()
2. PDC System - Immediate Targeting
PDCs work with direct node references, validated every frame:
gdscript# PDCSystem.gd
extends Node2D
class_name PDCSystem

# Identity
@export var pdc_id: String = ""
var mount_position: Vector2

# Immediate state - no stored IDs
var current_target: Node2D = null
var is_firing: bool = false

# Validation helper
func is_valid_target(target: Node2D) -> bool:
    if not target:
        return false
    if not is_instance_valid(target):
        return false
    if not target.has_method("mark_for_destruction"):
        return false
    if target.get("marked_for_death"):
        return false
    if not target.is_inside_tree():
        return false
    return true

func _physics_process(delta):
    # Validate target every frame
    if not is_valid_target(current_target):
        current_target = null
        stop_firing()
        return
    
    # Rest of PDC logic...
    update_aim(delta)
    handle_firing(delta)

func set_target(new_target: Node2D):
    # Direct node reference, no IDs
    if is_valid_target(new_target):
        current_target = new_target
        print("PDC %s: Engaging %s" % [pdc_id, new_target.get("torpedo_id")])
    else:
        print("PDC %s: Invalid target provided" % pdc_id)
        current_target = null

func fire_bullet():
    if not is_valid_target(current_target):
        return
        
    var bullet = bullet_scene.instantiate()
    get_tree().root.add_child(bullet)
    
    # Bullet carries PDC identity
    bullet.source_pdc_id = pdc_id
    bullet.set_meta("source_pdc", pdc_id)
    bullet.set_meta("fired_at", current_target.torpedo_id)
    
    # Calculate firing solution
    var intercept_point = calculate_intercept(current_target)
    bullet.velocity = (intercept_point - global_position).normalized() * bullet_speed
3. FireControlManager - Immediate Queries
No persistent tracking, just frame-by-frame decisions:
gdscript# FireControlManager.gd
extends Node2D
class_name FireControlManager

# PDC Registry (these are stable)
var registered_pdcs: Dictionary = {}  # pdc_id -> PDC node

# No tracked_targets! No stored references!

func _physics_process(delta):
    # Get current torpedo snapshot
    var torpedoes = get_valid_torpedoes()
    
    # Assign PDCs based on current state
    assign_pdcs_immediate(torpedoes)

func get_valid_torpedoes() -> Array:
    var valid_torpedoes = []
    
    # Query scene tree for current torpedoes
    var all_torpedoes = get_tree().get_nodes_in_group("torpedoes")
    
    for torpedo in all_torpedoes:
        if is_valid_combat_entity(torpedo):
            # Calculate current threat data
            var threat_data = assess_threat_immediate(torpedo)
            if threat_data.is_engageable:
                valid_torpedoes.append({
                    "node": torpedo,
                    "threat_data": threat_data
                })
    
    # Sort by priority
    valid_torpedoes.sort_custom(func(a, b): 
        return a.threat_data.priority > b.threat_data.priority
    )
    
    return valid_torpedoes

func assess_threat_immediate(torpedo: Node2D) -> Dictionary:
    var ship_pos = parent_ship.global_position
    var torpedo_pos = torpedo.global_position
    var torpedo_vel = torpedo.get("velocity_mps")
    
    # Calculate everything fresh
    var distance = ship_pos.distance_to(torpedo_pos)
    var closing_velocity = -torpedo_vel.dot((ship_pos - torpedo_pos).normalized())
    
    var time_to_impact = INF
    if closing_velocity > 0:
        time_to_impact = (distance * WorldSettings.meters_per_pixel) / closing_velocity
    
    return {
        "is_engageable": time_to_impact < 30.0 and distance < 50000,
        "time_to_impact": time_to_impact,
        "distance": distance,
        "priority": 1.0 / max(time_to_impact, 0.1)
    }

func assign_pdcs_immediate(torpedo_list: Array):
    # Clear all PDC targets first
    for pdc in registered_pdcs.values():
        if not pdc.is_valid_target(pdc.current_target):
            pdc.set_target(null)
    
    # Assign based on current snapshot
    for torpedo_data in torpedo_list:
        var torpedo = torpedo_data.node
        var best_pdc = find_best_pdc_for_target(torpedo)
        
        if best_pdc and not best_pdc.current_target:
            best_pdc.set_target(torpedo)

func find_best_pdc_for_target(torpedo: Node2D) -> PDCSystem:
    var best_pdc = null
    var best_score = -INF
    
    for pdc in registered_pdcs.values():
        if pdc.current_target:  # Already busy
            continue
            
        var score = calculate_pdc_efficiency(pdc, torpedo)
        if score > best_score:
            best_score = score
            best_pdc = pdc
    
    return best_pdc
4. EntityManager - Pure Observer
Records events without controlling anything:
gdscript# EntityManager.gd
extends Node
class_name EntityManager

# Pure event recording
var battle_events: Array = []
var frame_counter: int = 0

func _ready():
    # Listen for events
    add_to_group("battle_observers")

func _physics_process(delta):
    frame_counter += 1
    
    # Periodic snapshot of battle state
    if frame_counter % 60 == 0:  # Every second
        record_battle_snapshot()

func on_entity_dying(entity: Node2D, reason: String):
    # Called by entities when they die
    var event = {
        "type": "entity_destroyed",
        "timestamp": Time.get_ticks_msec() / 1000.0,
        "entity_type": entity.get_meta("entity_type", "unknown"),
        "entity_id": entity.get_meta("entity_id", "unknown"),
        "reason": reason,
        "position": entity.global_position
    }
    
    # Special handling for PDC kills
    if reason == "bullet_impact" and entity.has_meta("last_hit_by"):
        event["killed_by_pdc"] = entity.get_meta("last_hit_by")
    
    battle_events.append(event)

func record_battle_snapshot():
    # Count current entities
    var snapshot = {
        "type": "snapshot",
        "timestamp": Time.get_ticks_msec() / 1000.0,
        "torpedo_count": get_tree().get_nodes_in_group("torpedoes").size(),
        "bullet_count": get_tree().get_nodes_in_group("bullets").size(),
        "active_pdcs": count_active_pdcs()
    }
    battle_events.append(snapshot)
5. Collision System - Direct Attribution
Collisions handled immediately with clear ownership:
gdscript# PDCBullet.gd
extends Area2D
class_name PDCBullet

@export var source_pdc_id: String = ""
var velocity: Vector2

func _ready():
    add_to_group("bullets")
    add_to_group("combat_entities")
    area_entered.connect(_on_area_entered)

func _on_area_entered(other: Area2D):
    # Direct collision handling
    if not other.is_in_group("torpedoes"):
        return
    
    # Mark torpedo with hit info
    if other.has_method("mark_for_destruction"):
        other.set_meta("last_hit_by", source_pdc_id)
        other.mark_for_destruction("bullet_impact")
    
    # Self destruct
    queue_free()

Implementation Benefits
1. No Ghost References

Nodes are either valid or null, no in-between
Every frame gets fresh data
No stale reference bugs

2. Simple Debugging
gdscript# Add this to any system
func debug_current_state():
    print("=== %s State ===" % name)
    print("Valid torpedoes: %d" % get_tree().get_nodes_in_group("torpedoes").size())
    for pdc_id in registered_pdcs:
        var pdc = registered_pdcs[pdc_id]
        print("  %s -> %s" % [pdc_id, pdc.current_target.torpedo_id if pdc.current_target else "none"])
3. Natural Resilience

Systems work independently
No cascading failures
Graceful degradation

4. Performance

No complex tracking dictionaries
Direct node queries are fast
Simpler code paths


Migration Strategy
Phase 1: Node Identity

Add identity properties to all combat nodes
Implement mark_for_destruction() pattern
Test destruction handling

Phase 2: PDC Immediate Mode

Refactor PDCs to use direct references
Add frame-by-frame validation
Remove ID-based targeting

Phase 3: FireControl Simplification

Remove tracked_targets system
Implement immediate assignment
Test with multiple scenarios

Phase 4: Pure Observer EntityManager

Strip control functions
Enhance event recording
Verify battle analytics

Phase 5: Integration Testing

Test with 100+ torpedoes
Verify PDC target distribution
Confirm accurate battle reports


Success Metrics

Zero ghost target bugs - PDCs never fire at nothing
Even PDC distribution - Both PDCs get similar hit counts
Accurate attribution - Every kill traced to correct PDC
Clean battle reports - No counting errors or mismatches
Predictable behavior - Same scenario = same result

This architecture embraces Godot's reality instead of fighting it. Simpler, cleaner, bulletproof.