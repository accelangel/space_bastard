# Scripts/Managers/EntityManager.gd - WITH ENTITY SELF-REPORTING
extends Node

# Core entity tracking (unchanged)
var entities: Dictionary = {}
var entity_lookup: Dictionary = {}
var spatial_grid: SpatialGrid
var grid_cell_size: float = 1000.0

# Entity type groups for fast filtering
var entities_by_type: Dictionary = {}
var entities_by_faction: Dictionary = {}

# Lifecycle tracking
var pending_spawns: Array[EntityData] = []
var pending_updates: Array[String] = []
var pending_destroys: Array[String] = []

# NEW: Radar system registry
var active_radar_systems: Array[SensorSystem] = []

# Performance settings
var max_updates_per_frame: int = 50
var spatial_update_interval: float = 0.1
var spatial_update_timer: float = 0.0

# NEW: Entity reporting settings
var entity_report_interval: float = 0.0166667  # 60 Hz entity reports
var entity_report_timer: float = 0.0
var entities_to_report: Array[String] = []     # Queue for this frame

# Statistics
var total_entities_created: int = 0
var total_entities_destroyed: int = 0
var total_reports_sent: int = 0

# Enums (unchanged)
enum EntityType {
	UNKNOWN, PLAYER_SHIP, ENEMY_SHIP, NEUTRAL_SHIP,
	TORPEDO, MISSILE, PROJECTILE, ASTEROID, STATION,
	PICKUP, EFFECT, SENSOR_CONTACT
}

enum FactionType {
	NEUTRAL, PLAYER, ENEMY, CIVILIAN
}

enum EntityState {
	SPAWNING, ACTIVE, DAMAGED, DISABLED, DESTROYED, CLEANUP
}

# EntityData class (unchanged from previous version)
class EntityData:
	var entity_id: String
	var node_ref: Node2D
	var entity_type: EntityType
	var faction_type: FactionType
	var state: EntityState
	
	var position: Vector2
	var velocity: Vector2
	var radius: float
	var last_spatial_update: float
	
	var owner_id: String
	var target_ids: Array[String] = []
	var targeting_ids: Array[String] = []
	
	var creation_time: float
	var last_update_time: float
	var custom_data: Dictionary = {}
	
	func _init(id: String, node: Node2D, type: EntityType, faction_val: FactionType):
		entity_id = id
		node_ref = node
		entity_type = type
		faction_type = faction_val
		state = EntityState.SPAWNING
		position = node.global_position if node else Vector2.ZERO
		velocity = Vector2.ZERO
		radius = 50.0
		creation_time = Time.get_ticks_msec() / 1000.0
		last_update_time = creation_time
		last_spatial_update = creation_time
	
	func is_valid() -> bool:
		return node_ref != null and is_instance_valid(node_ref) and state != EntityState.DESTROYED
	
	func update_position():
		if is_valid():
			position = node_ref.global_position
			last_update_time = Time.get_ticks_msec() / 1000.0
			
			if node_ref.has_method("get_velocity_mps"):
				velocity = node_ref.get_velocity_mps()
			elif "velocity_mps" in node_ref:
				velocity = node_ref.velocity_mps
	
	func get_debug_info() -> String:
		var type_name = EntityType.keys()[entity_type]
		var faction_name = FactionType.keys()[faction_type]
		var state_name = EntityState.keys()[state]
		return "%s [%s:%s:%s] at %s" % [entity_id, type_name, faction_name, state_name, position]

# Spatial Grid class (unchanged)
class SpatialGrid:
	var grid: Dictionary = {}
	var cell_size: float
	var entity_positions: Dictionary = {}
	var entity_manager_ref: Node
	
	func _init(size: float, manager_ref: Node):
		cell_size = size
		entity_manager_ref = manager_ref
	
	func get_cell_coord(position: Vector2) -> Vector2i:
		return Vector2i(int(position.x / cell_size), int(position.y / cell_size))
	
	func add_entity(entity_id: String, position: Vector2):
		var cell = get_cell_coord(position)
		remove_entity(entity_id)
		if not grid.has(cell):
			grid[cell] = []
		grid[cell].append(entity_id)
		entity_positions[entity_id] = cell
	
	func remove_entity(entity_id: String):
		if entity_positions.has(entity_id):
			var old_cell = entity_positions[entity_id]
			if grid.has(old_cell):
				grid[old_cell].erase(entity_id)
				if grid[old_cell].is_empty():
					grid.erase(old_cell)
			entity_positions.erase(entity_id)
	
	func get_entities_in_radius(center: Vector2, radius: float) -> Array[String]:
		var result: Array[String] = []
		var radius_squared = radius * radius
		var min_cell = get_cell_coord(center - Vector2(radius, radius))
		var max_cell = get_cell_coord(center + Vector2(radius, radius))
		
		for x in range(min_cell.x, max_cell.x + 1):
			for y in range(min_cell.y, max_cell.y + 1):
				var cell = Vector2i(x, y)
				if grid.has(cell):
					for entity_id in grid[cell]:
						var entity_pos = entity_manager_ref.get_entity_position(entity_id)
						if entity_pos.distance_squared_to(center) <= radius_squared:
							result.append(entity_id)
		return result

func _ready():
	spatial_grid = SpatialGrid.new(grid_cell_size, self)
	
	if get_tree():
		get_tree().node_removed.connect(_on_node_removed)
	
	print("EntityManager initialized with self-reporting")
	print("  Grid cell size: ", grid_cell_size, " pixels")
	print("  Entity report frequency: ", 1.0 / entity_report_interval, " Hz")

func _physics_process(delta):
	spatial_update_timer += delta
	entity_report_timer += delta
	
	_process_spawns()
	_process_updates()
	_process_destroys()
	
	# NEW: Process entity reports to radar systems
	if entity_report_timer >= entity_report_interval:
		process_entity_reports()
		entity_report_timer = 0.0
	
	if spatial_update_timer >= spatial_update_interval:
		_update_spatial_index()
		spatial_update_timer = 0.0

# NEW: Register a radar system to receive entity reports
func register_radar_system(radar_system: SensorSystem):
	if radar_system not in active_radar_systems:
		active_radar_systems.append(radar_system)
		var ship_name = "unknown"
		if radar_system.parent_ship:
			ship_name = radar_system.parent_ship.name
		print("EntityManager: Registered radar system from ", ship_name)

# NEW: Process entity reports to all radar systems
func process_entity_reports():
	if active_radar_systems.is_empty():
		return  # No radar systems to report to
	
	var reports_sent_this_frame = 0
	
	# Report all active entities to all radar systems
	for entity_data in entities.values():
		if entity_data.state != EntityState.ACTIVE:
			continue
		
		if not entity_data.is_valid():
			continue
		
		# Update entity position first
		entity_data.update_position()
		
		# Report to all radar systems
		for radar_system in active_radar_systems:
			if radar_system and is_instance_valid(radar_system):
				radar_system.receive_entity_report(
					entity_data.entity_id,
					entity_data.position,
					entity_data.velocity,
					entity_data.entity_type,
					entity_data.faction_type
				)
				reports_sent_this_frame += 1
			else:
				# Clean up invalid radar systems
				active_radar_systems.erase(radar_system)
	
	total_reports_sent += reports_sent_this_frame
	
	if reports_sent_this_frame > 0:
		print("EntityManager: Sent ", reports_sent_this_frame, " reports to ", active_radar_systems.size(), " radar systems")

# All other methods remain unchanged from the original EntityManager
func register_entity(node: Node2D, entity_type: EntityType, faction_type: FactionType = FactionType.NEUTRAL, 
					 owner_id: String = "") -> String:
	if not node or not is_instance_valid(node):
		push_error("Attempted to register invalid node as entity")
		return ""
	
	var entity_id = _generate_entity_id(node)
	
	if entities.has(entity_id):
		print("Warning: Entity already registered: ", entity_id)
		return entity_id
	
	var entity_data = EntityData.new(entity_id, node, entity_type, faction_type)
	entity_data.owner_id = owner_id
	entity_data.radius = _get_default_radius(entity_type, node)
	
	entities[entity_id] = entity_data
	entity_lookup[node] = entity_id
	
	_add_to_group(entities_by_type, entity_type, entity_id)
	_add_to_group(entities_by_faction, faction_type, entity_id)
	
	pending_spawns.append(entity_data)
	total_entities_created += 1
	
	print("Registered entity: ", entity_data.get_debug_info())
	return entity_id

func update_entity(entity_id: String, force_spatial_update: bool = false):
	if not entities.has(entity_id):
		return
	
	var entity_data = entities[entity_id]
	if not entity_data.is_valid():
		queue_destroy_entity(entity_id)
		return
	
	var old_position = entity_data.position
	entity_data.update_position()
	
	if force_spatial_update or old_position.distance_squared_to(entity_data.position) > 100.0:
		if entity_id not in pending_updates:
			pending_updates.append(entity_id)

func set_entity_state(entity_id: String, new_state: EntityState):
	if not entities.has(entity_id):
		return
	
	var entity_data = entities[entity_id]
	var old_state = entity_data.state
	entity_data.state = new_state
	
	print("Entity state changed: ", entity_id, " from ", EntityState.keys()[old_state], 
		  " to ", EntityState.keys()[new_state])
	
	match new_state:
		EntityState.ACTIVE:
			if old_state == EntityState.SPAWNING:
				print("Entity spawned: ", entity_id)
		EntityState.DESTROYED:
			queue_destroy_entity(entity_id)

func queue_destroy_entity(entity_id: String):
	if entity_id not in pending_destroys:
		pending_destroys.append(entity_id)

func get_entity(entity_id: String) -> EntityData:
	return entities.get(entity_id)

func get_entity_for_node(node: Node2D) -> EntityData:
	if not entity_lookup.has(node):
		return null
	var entity_id = entity_lookup[node]
	return entities.get(entity_id)

func get_entity_position(entity_id: String) -> Vector2:
	if entities.has(entity_id):
		return entities[entity_id].position
	return Vector2.ZERO

# SPATIAL QUERIES - Now much less used since radar uses self-reporting
func get_entities_in_radius(center: Vector2, radius: float, 
							entity_types: Array[EntityType] = [], 
							factions: Array[FactionType] = [],
							exclude_states: Array[EntityState] = [EntityState.DESTROYED]) -> Array[EntityData]:
	var candidate_ids = spatial_grid.get_entities_in_radius(center, radius)
	return _filter_entities(candidate_ids, entity_types, factions, exclude_states)

func get_closest_entity(center: Vector2, max_range: float = INF,
						entity_types: Array[EntityType] = [],
						factions: Array[FactionType] = [],
						exclude_entity: String = "") -> EntityData:
	var candidates = get_entities_in_radius(center, max_range, entity_types, factions)
	
	var closest: EntityData = null
	var closest_distance_sq = max_range * max_range
	
	for entity_data in candidates:
		if entity_data.entity_id == exclude_entity:
			continue
		
		var distance_sq = center.distance_squared_to(entity_data.position)
		if distance_sq < closest_distance_sq:
			closest = entity_data
			closest_distance_sq = distance_sq
	
	return closest

func get_entities_by_type(entity_types: Array[EntityType]) -> Array[EntityData]:
	var result: Array[EntityData] = []
	
	for entity_type in entity_types:
		if entities_by_type.has(entity_type):
			for entity_id in entities_by_type[entity_type]:
				if entities.has(entity_id):
					result.append(entities[entity_id])
	
	return result

func get_entities_by_faction(factions: Array[FactionType]) -> Array[EntityData]:
	var result: Array[EntityData] = []
	
	for faction_type in factions:
		if entities_by_faction.has(faction_type):
			for entity_id in entities_by_faction[faction_type]:
				if entities.has(entity_id):
					result.append(entities[entity_id])
	
	return result

func set_targeting_relationship(hunter_id: String, target_id: String):
	if not entities.has(hunter_id) or not entities.has(target_id):
		return
	
	var hunter = entities[hunter_id]
	var target = entities[target_id]
	
	if target_id not in hunter.target_ids:
		hunter.target_ids.append(target_id)
	
	if hunter_id not in target.targeting_ids:
		target.targeting_ids.append(hunter_id)

func remove_targeting_relationship(hunter_id: String, target_id: String):
	if entities.has(hunter_id):
		entities[hunter_id].target_ids.erase(target_id)
	
	if entities.has(target_id):
		entities[target_id].targeting_ids.erase(hunter_id)

# Internal methods (unchanged)
func _process_spawns():
	for entity_data in pending_spawns:
		if entity_data.is_valid():
			entity_data.update_position()
			spatial_grid.add_entity(entity_data.entity_id, entity_data.position)
			entity_data.state = EntityState.ACTIVE
	
	pending_spawns.clear()

func _process_updates():
	var processed = 0
	var updates_to_process = pending_updates.duplicate()
	pending_updates.clear()
	
	for entity_id in updates_to_process:
		if processed >= max_updates_per_frame:
			pending_updates.append(entity_id)
			continue
		
		if entities.has(entity_id):
			var entity_data = entities[entity_id]
			if entity_data.is_valid():
				var old_pos = entity_data.position
				entity_data.update_position()
				
				if old_pos != entity_data.position:
					spatial_grid.add_entity(entity_id, entity_data.position)
					entity_data.last_spatial_update = Time.get_ticks_msec() / 1000.0
		
		processed += 1

func _process_destroys():
	for entity_id in pending_destroys:
		_destroy_entity(entity_id)
	
	pending_destroys.clear()

func _destroy_entity(entity_id: String):
	if not entities.has(entity_id):
		return
	
	var entity_data = entities[entity_id]
	
	spatial_grid.remove_entity(entity_id)
	_remove_from_group(entities_by_type, entity_data.entity_type, entity_id)
	_remove_from_group(entities_by_faction, entity_data.faction_type, entity_id)
	
	for target_id in entity_data.target_ids:
		remove_targeting_relationship(entity_id, target_id)
	
	for hunter_id in entity_data.targeting_ids:
		remove_targeting_relationship(hunter_id, entity_id)
	
	if entity_data.node_ref and entity_lookup.has(entity_data.node_ref):
		entity_lookup.erase(entity_data.node_ref)
	
	entities.erase(entity_id)
	total_entities_destroyed += 1
	
	print("Destroyed entity: ", entity_id)

func _update_spatial_index():
	for entity_data in entities.values():
		if entity_data.is_valid() and entity_data.state == EntityState.ACTIVE:
			var old_pos = entity_data.position
			entity_data.update_position()
			
			if old_pos.distance_squared_to(entity_data.position) > 25.0:
				spatial_grid.add_entity(entity_data.entity_id, entity_data.position)
				entity_data.last_spatial_update = Time.get_ticks_msec() / 1000.0

func _on_node_removed(node: Node):
	if entity_lookup.has(node):
		var entity_id = entity_lookup[node]
		print("Node removed from scene, queuing entity for destruction: ", entity_id)
		queue_destroy_entity(entity_id)

func _generate_entity_id(node: Node2D) -> String:
	return node.name + "_" + str(node.get_instance_id())

func _get_default_radius(entity_type: EntityType, node: Node2D) -> float:
	if node.has_method("get_collision_radius"):
		return node.get_collision_radius()
	
	match entity_type:
		EntityType.PLAYER_SHIP, EntityType.ENEMY_SHIP, EntityType.NEUTRAL_SHIP:
			return 75.0
		EntityType.TORPEDO, EntityType.MISSILE:
			return 25.0
		EntityType.PROJECTILE:
			return 10.0
		EntityType.ASTEROID:
			return 100.0
		EntityType.STATION:
			return 200.0
		EntityType.PICKUP:
			return 30.0
		EntityType.EFFECT:
			return 50.0
		EntityType.SENSOR_CONTACT:
			return 25.0
		_:
			return 50.0

func _filter_entities(entity_ids: Array[String], 
					 entity_types: Array[EntityType] = [],
					 factions: Array[FactionType] = [],
					 exclude_states: Array[EntityState] = []) -> Array[EntityData]:
	var result: Array[EntityData] = []
	
	for entity_id in entity_ids:
		if not entities.has(entity_id):
			continue
		
		var entity_data = entities[entity_id]
		
		if entity_types.size() > 0 and entity_data.entity_type not in entity_types:
			continue
		
		if factions.size() > 0 and entity_data.faction_type not in factions:
			continue
		
		if entity_data.state in exclude_states:
			continue
		
		result.append(entity_data)
	
	return result

func _add_to_group(group_dict: Dictionary, key, entity_id: String):
	if not group_dict.has(key):
		group_dict[key] = []
	if entity_id not in group_dict[key]:
		group_dict[key].append(entity_id)

func _remove_from_group(group_dict: Dictionary, key, entity_id: String):
	if group_dict.has(key):
		group_dict[key].erase(entity_id)
		if group_dict[key].is_empty():
			group_dict.erase(key)

func get_debug_info() -> String:
	var active_count = 0
	var by_type_counts = {}
	var by_faction_counts = {}
	
	for entity_data in entities.values():
		if entity_data.state == EntityState.ACTIVE:
			active_count += 1
		
		var type_key = EntityType.keys()[entity_data.entity_type]
		by_type_counts[type_key] = by_type_counts.get(type_key, 0) + 1
		
		var faction_key = FactionType.keys()[entity_data.faction_type]
		by_faction_counts[faction_key] = by_faction_counts.get(faction_key, 0) + 1
	
	return "Entities: %d total, %d active | Radar Systems: %d | Reports Sent: %d" % [
		entities.size(), active_count, active_radar_systems.size(), total_reports_sent
	]

func get_performance_stats() -> Dictionary:
	return {
		"total_entities": entities.size(),
		"active_entities": entities.values().filter(func(e): return e.state == EntityState.ACTIVE).size(),
		"spatial_cells": spatial_grid.grid.size(),
		"radar_systems": active_radar_systems.size(),
		"reports_sent": total_reports_sent,
		"created": total_entities_created,
		"destroyed": total_entities_destroyed
	}
