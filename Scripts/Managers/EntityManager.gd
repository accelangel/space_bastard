# Scripts/Managers/EntityManager.gd - SIMPLIFIED VERSION
extends Node

# Core entity tracking
var entities: Dictionary = {}  # entity_id -> EntityData
var entity_id_counter: int = 0

# Performance
var update_interval: float = 0.0166667  # 60 Hz
var update_timer: float = 0.0

# Map boundaries for auto-cleanup
var map_bounds: Rect2

class EntityData:
	var entity_id: String
	var node_ref: Node2D
	var entity_type: String  # "player_ship", "enemy_ship", "torpedo", "pdc_bullet"
	var faction: String       # "friendly" or "hostile"
	var position: Vector2
	var last_update: float
	
	func _init(id: String, node: Node2D, type: String, fact: String):
		entity_id = id
		node_ref = node
		entity_type = type
		faction = fact
		position = node.global_position if node else Vector2.ZERO
		last_update = Time.get_ticks_msec() / 1000.0

func _ready():
	# Set up map boundaries for auto-cleanup
	var half_size = WorldSettings.map_size_pixels / 2
	map_bounds = Rect2(-half_size, -half_size, WorldSettings.map_size_pixels.x, WorldSettings.map_size_pixels.y)
	
	print("EntityManager initialized (Simplified)")
	print("Map bounds: ", map_bounds)

func _physics_process(delta):
	update_timer += delta
	
	if update_timer >= update_interval:
		update_timer = 0.0
		
		# Send position reports to all sensor systems
		var all_positions = []
		for entity_data in entities.values():
			if is_instance_valid(entity_data.node_ref):
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

func register_entity(node: Node2D, type: String, faction: String) -> String:
	entity_id_counter += 1
	var entity_id = type + "_" + str(entity_id_counter)
	
	var entity_data = EntityData.new(entity_id, node, type, faction)
	entities[entity_id] = entity_data
	
	print("Registered entity: ", entity_id, " (", type, ", ", faction, ")")
	return entity_id

func update_entity_position(entity_id: String, new_position: Vector2):
	if entities.has(entity_id):
		entities[entity_id].position = new_position
		entities[entity_id].last_update = Time.get_ticks_msec() / 1000.0

func unregister_entity(entity_id: String):
	if entities.has(entity_id):
		print("Unregistered entity: ", entity_id)
		entities.erase(entity_id)

func cleanup_out_of_bounds():
	var to_remove = []
	
	for entity_id in entities:
		var entity_data = entities[entity_id]
		
		# Check if node is still valid
		if not is_instance_valid(entity_data.node_ref):
			to_remove.append(entity_id)
			continue
		
		# Check if out of bounds
		if not map_bounds.has_point(entity_data.position):
			print("Entity out of bounds, removing: ", entity_id)
			if entity_data.node_ref:
				entity_data.node_ref.queue_free()
			to_remove.append(entity_id)
	
	# Remove invalid entities
	for entity_id in to_remove:
		entities.erase(entity_id)

func get_all_entities() -> Array:
	var result = []
	for entity_data in entities.values():
		if is_instance_valid(entity_data.node_ref):
			result.append(entity_data)
	return result

func get_entities_by_type(type: String) -> Array:
	var result = []
	for entity_data in entities.values():
		if entity_data.entity_type == type and is_instance_valid(entity_data.node_ref):
			result.append(entity_data)
	return result

func get_debug_info() -> String:
	var type_counts = {}
	for entity_data in entities.values():
		if type_counts.has(entity_data.entity_type):
			type_counts[entity_data.entity_type] += 1
		else:
			type_counts[entity_data.entity_type] = 1
	
	return "Entities: %d total | %s" % [entities.size(), type_counts]
