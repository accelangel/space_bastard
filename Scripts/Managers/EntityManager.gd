# Scripts/Managers/EntityManager.gd - ENHANCED FOR BATTLE REFACTOR
extends Node

# Core entity tracking
var entities: Dictionary = {}  # entity_id -> EntityData
var entity_id_counter: int = 0

# NEW: Battle event recording system
var battle_events: Array = []
var entity_registry: Dictionary = {}  # Full lifecycle tracking

# NEW: Collision deduplication system
var pending_collisions: Dictionary = {}  # collision_key -> frame_number
var current_frame: int = 0

# Performance
var update_interval: float = 0.0166667  # 60 Hz
var update_timer: float = 0.0

# Map boundaries for auto-cleanup
var map_bounds: Rect2

# DEBUG CONTROL - Minimal logging only
@export var debug_enabled: bool = false
var debug_timer: float = 0.0
var debug_interval: float = 30.0

class EntityData:
	var entity_id: String
	var node_ref: Node2D
	var entity_type: String  # "player_ship", "enemy_ship", "torpedo", "pdc_bullet"
	var faction: String       # "friendly" or "hostile"
	var position: Vector2
	var last_update: float
	var source_pdc: String = ""  # NEW: For bullets only - which PDC fired this
	var birth_time: float
	var is_destroyed: bool = false
	
	func _init(id: String, node: Node2D, type: String, fact: String, source: String = ""):
		entity_id = id
		node_ref = node
		entity_type = type
		faction = fact
		source_pdc = source
		position = node.global_position if node else Vector2.ZERO
		birth_time = Time.get_ticks_msec() / 1000.0
		last_update = birth_time

func _ready():
	# Set up map boundaries for auto-cleanup
	var half_size = WorldSettings.map_size_pixels / 2
	map_bounds = Rect2(-half_size.x, -half_size.y, WorldSettings.map_size_pixels.x, WorldSettings.map_size_pixels.y)
	
	print("EntityManager initialized - Battle tracking enabled")

func _physics_process(delta):
	current_frame += 1  # Collision deduplication frame counter
	
	update_timer += delta
	
	if update_timer >= update_interval:
		update_timer = 0.0
		
		# Send position reports to all sensor systems
		var all_positions = []
		for entity_data in entities.values():
			if is_instance_valid(entity_data.node_ref) and not entity_data.is_destroyed:
				all_positions.append({
					"node": entity_data.node_ref,
					"position": entity_data.position,
					"type": entity_data.entity_type,
					"faction": entity_data.faction
				})
		
		# Update all sensor systems
		var sensor_systems = get_tree().get_nodes_in_group("sensor_systems")
		for sensor in sensor_systems:
			if sensor.has_method("update_contacts"):
				sensor.update_contacts(all_positions)
		
		# Clean up out-of-bounds entities
		cleanup_out_of_bounds()
		
		# Periodic debug output (much less frequent)
		if debug_enabled:
			debug_timer += delta
			if debug_timer >= debug_interval:
				debug_timer = 0.0
				print_debug_summary()

# ENHANCED: Registration now supports source PDC for bullets
func register_entity(node: Node2D, type: String, faction: String, source_pdc: String = "") -> String:
	entity_id_counter += 1
	var entity_id = type + "_" + str(entity_id_counter)
	
	var entity_data = EntityData.new(entity_id, node, type, faction, source_pdc)
	entities[entity_id] = entity_data
	entity_registry[entity_id] = entity_data  # Also track in registry
	
	# Record birth event
	record_battle_event({
		"type": "entity_registered",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"entity_id": entity_id,
		"entity_type": type,
		"faction": faction,
		"position": entity_data.position,
		"source_pdc": source_pdc
	})
	
	# Set entity_id on the node for collision reporting
	if node.has_method("set"):
		node.set("entity_id", entity_id)
	
	return entity_id

func update_entity_position(entity_id: String, new_position: Vector2):
	if entities.has(entity_id):
		entities[entity_id].position = new_position
		entities[entity_id].last_update = Time.get_ticks_msec() / 1000.0

# NEW: Collision reporting system with deduplication
func report_collision(entity1_id: String, entity2_id: String, collision_position: Vector2):
	# Prevent duplicate collision reports in same frame
	var collision_key = get_collision_key(entity1_id, entity2_id)
	
	if pending_collisions.has(collision_key) and pending_collisions[collision_key] == current_frame:
		return  # Already processed this collision this frame
	
	pending_collisions[collision_key] = current_frame
	
	# Validate both entities exist and aren't already destroyed
	if not entities.has(entity1_id) or not entities.has(entity2_id):
		return
	
	var entity1 = entities[entity1_id]
	var entity2 = entities[entity2_id]
	
	if entity1.is_destroyed or entity2.is_destroyed:
		return  # Already destroyed
	
	# Check if this is a hostile collision (different factions)
	if entity1.faction == entity2.faction:
		return  # Friendly fire ignored
	
	# Record collision event
	record_battle_event({
		"type": "collision",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"entity1_id": entity1_id,
		"entity2_id": entity2_id,
		"entity1_type": entity1.entity_type,
		"entity2_type": entity2.entity_type,
		"position": collision_position,
		"entity1_faction": entity1.faction,
		"entity2_faction": entity2.faction
	})
	
	# Destroy both entities involved in collision
	destroy_entity_safe(entity1_id, "collision")
	destroy_entity_safe(entity2_id, "collision")

func get_collision_key(id1: String, id2: String) -> String:
	# Create consistent key regardless of order
	if id1 < id2:
		return id1 + "_" + id2
	else:
		return id2 + "_" + id1

# NEW: Safe entity destruction with event recording
func destroy_entity_safe(entity_id: String, reason: String):
	if not entities.has(entity_id):
		return
	
	var entity_data = entities[entity_id]
	
	if entity_data.is_destroyed:
		return  # Already destroyed
	
	# Mark as destroyed to prevent double-destruction
	entity_data.is_destroyed = true
	
	# Record destruction event
	record_battle_event({
		"type": "entity_destroyed",
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"entity_id": entity_id,
		"entity_type": entity_data.entity_type,
		"faction": entity_data.faction,
		"position": entity_data.position,
		"destruction_reason": reason,
		"source_pdc": entity_data.source_pdc,
		"lifetime": (Time.get_ticks_msec() / 1000.0) - entity_data.birth_time
	})
	
	# Queue the actual node for destruction
	if is_instance_valid(entity_data.node_ref):
		entity_data.node_ref.queue_free()

func unregister_entity(entity_id: String):
	if entities.has(entity_id):
		var entity_data = entities[entity_id]
		
		# If not already recorded as destroyed, record it now
		if not entity_data.is_destroyed:
			destroy_entity_safe(entity_id, "manual_cleanup")
		
		entities.erase(entity_id)

func cleanup_out_of_bounds():
	var to_remove = []
	
	for entity_id in entities:
		var entity_data = entities[entity_id]
		
		# Check if node is still valid
		if not is_instance_valid(entity_data.node_ref):
			if not entity_data.is_destroyed:
				destroy_entity_safe(entity_id, "node_invalid")
			to_remove.append(entity_id)
			continue
		
		# Check if out of bounds
		if not map_bounds.has_point(entity_data.position):
			destroy_entity_safe(entity_id, "out_of_bounds")
			to_remove.append(entity_id)
	
	# Remove invalid entities from tracking
	for entity_id in to_remove:
		entities.erase(entity_id)

# NEW: Battle data interface for BattleManager
func get_battle_data() -> Dictionary:
	return {
		"events": battle_events.duplicate(),
		"entity_registry": entity_registry.duplicate()
	}

func clear_battle_data():
	battle_events.clear()
	entity_registry.clear()
	print("EntityManager: Battle data cleared for new battle")

func record_battle_event(event_data: Dictionary):
	battle_events.append(event_data)

# Enhanced debugging
func print_debug_summary():
	var type_counts = {}
	var active_count = 0
	
	for entity_data in entities.values():
		if not entity_data.is_destroyed:
			active_count += 1
			if type_counts.has(entity_data.entity_type):
				type_counts[entity_data.entity_type] += 1
			else:
				type_counts[entity_data.entity_type] = 1
	
	print("EntityManager: %d active entities, %d total events recorded" % [active_count, battle_events.size()])

# Utility functions remain the same
func get_all_entities() -> Array:
	var result = []
	for entity_data in entities.values():
		if is_instance_valid(entity_data.node_ref) and not entity_data.is_destroyed:
			result.append(entity_data)
	return result

func get_entities_by_type(type: String) -> Array:
	var result = []
	for entity_data in entities.values():
		if entity_data.entity_type == type and is_instance_valid(entity_data.node_ref) and not entity_data.is_destroyed:
			result.append(entity_data)
	return result

func get_debug_info() -> String:
	var active_count = 0
	for entity_data in entities.values():
		if not entity_data.is_destroyed:
			active_count += 1
	return "Entities: %d active, %d events" % [active_count, battle_events.size()]
