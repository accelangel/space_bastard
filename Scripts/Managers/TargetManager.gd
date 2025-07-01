# Scripts/Managers/TargetManager.gd
extends Node

# Dictionary of all tracked targets: target_id -> TargetData
var targets: Dictionary = {}

# Dictionary of entity -> target_id mappings for quick lookup
var entity_to_target_id: Dictionary = {}

# Settings
var cleanup_interval: float = 1.0  # How often to clean up old targets
var cleanup_timer: float = 0.0

# Statistics for debugging
var total_targets_created: int = 0
var total_targets_cleaned: int = 0

func _ready():
	print("TargetManager initialized")
	
	# Connect to SceneTree to handle node removal
	if get_tree():
		get_tree().node_removed.connect(_on_node_removed)

# CRITICAL FIX: Move to _physics_process to match torpedo timing
func _physics_process(delta):
	cleanup_timer += delta
	
	# Update all target positions every physics frame
	update_all_targets()
	
	# Update all target data age and confidence
	for target_data in targets.values():
		target_data.update_age_and_confidence()
	
	# Periodic cleanup
	if cleanup_timer >= cleanup_interval:
		cleanup_stale_targets()
		cleanup_timer = 0.0

# Handle when nodes are removed from the scene tree
func _on_node_removed(node: Node):
	if entity_to_target_id.has(node):
		var target_id = entity_to_target_id[node]
		print("Node removed from scene, cleaning up target: ", target_id)
		entity_to_target_id.erase(node)
		
		# Mark target data as lost contact if it exists
		if targets.has(target_id):
			var target_data = targets[target_id]
			target_data.target_node = null
			target_data.data_source = TargetData.DataSource.LOST_CONTACT

# Update all targets with direct visual contact
func update_all_targets():
	for target_data in targets.values():
		# Only update direct visual contacts automatically
		if target_data.data_source == TargetData.DataSource.DIRECT_VISUAL:
			if target_data.target_node and is_instance_valid(target_data.target_node):
				# Get velocity if available
				var vel = Vector2.ZERO
				if target_data.target_node.has_method("get_velocity_mps"):
					vel = target_data.target_node.get_velocity_mps()
				elif "velocity_mps" in target_data.target_node:
					vel = target_data.target_node.velocity_mps
				
				# Update with current position and velocity
				target_data.update_data(
					target_data.target_node.global_position,
					vel,
					TargetData.DataSource.DIRECT_VISUAL
				)

# Clean up old or invalid targets
func cleanup_stale_targets():
	var targets_to_remove = []
	
	for target_id in targets.keys():
		var target_data = targets[target_id]
		
		# Remove invalid targets
		if not target_data.is_valid():
			targets_to_remove.append(target_id)
			continue
		
		# Remove targets that have been lost for too long
		if target_data.data_source == TargetData.DataSource.LOST_CONTACT and target_data.data_age > 30.0:
			targets_to_remove.append(target_id)
	
	# Actually remove the targets
	for target_id in targets_to_remove:
		remove_target(target_id)

# Remove a target from tracking
func remove_target(target_id: String):
	if not targets.has(target_id):
		return
	
	var target_data = targets[target_id]
	
	# Remove from entity mapping if it exists
	if target_data.target_node and entity_to_target_id.has(target_data.target_node):
		entity_to_target_id.erase(target_data.target_node)
	
	# Remove from main targets dictionary
	targets.erase(target_id)
	total_targets_cleaned += 1
	
	print("Removed target: ", target_id, " (Total cleaned: ", total_targets_cleaned, ")")

# Register a new target or update existing one
func register_target(node: Node2D, data_source: TargetData.DataSource = TargetData.DataSource.DIRECT_VISUAL) -> TargetData:
	if not node or not is_instance_valid(node):
		push_error("Attempted to register invalid node as target")
		return null
	
	var target_id = node.name + "_" + str(node.get_instance_id())
	
	# If target already exists, update it
	if targets.has(target_id):
		var existing_data = targets[target_id]
		existing_data.update_data(node.global_position, Vector2.ZERO, data_source)
		existing_data.target_node = node  # Ensure node reference is current
		print("Updated existing target: ", target_id)
		return existing_data
	
	# Create new target data
	var target_data = TargetData.new(target_id, node, node.global_position)
	target_data.data_source = data_source
	
	# Store in both dictionaries
	targets[target_id] = target_data
	entity_to_target_id[node] = target_id
	
	total_targets_created += 1
	print("Registered new target: ", target_id, " at ", node.global_position)
	
	return target_data

# Update target data manually (for sensor systems)
func update_target_data(target_id: String, position: Vector2, velocity: Vector2 = Vector2.ZERO, 
						data_source: TargetData.DataSource = TargetData.DataSource.RADAR_CONTACT) -> bool:
	if not targets.has(target_id):
		print("Warning: Attempted to update non-existent target: ", target_id)
		return false
	
	var target_data = targets[target_id]
	target_data.update_data(position, velocity, data_source)
	return true

# Get target data by ID
func get_target_data(target_id: String) -> TargetData:
	return targets.get(target_id)

# Get target data by node reference
func get_target_data_for_node(node: Node2D) -> TargetData:
	if not entity_to_target_id.has(node):
		return null
	
	var target_id = entity_to_target_id[node]
	return targets.get(target_id)

# Get all targets matching criteria
func get_targets_by_criteria(min_confidence: float = 0.0, max_age: float = INF, 
							valid_sources: Array[TargetData.DataSource] = []) -> Array[TargetData]:
	var result: Array[TargetData] = []
	
	for target_data in targets.values():
		# Check confidence
		if target_data.confidence < min_confidence:
			continue
		
		# Check age
		if target_data.data_age > max_age:
			continue
		
		# Check data source
		if valid_sources.size() > 0 and target_data.data_source not in valid_sources:
			continue
		
		result.append(target_data)
	
	return result

# Get all targets within range of a position
func get_targets_in_range(center_pos: Vector2, range_pixels: float, 
						 min_confidence: float = 0.0) -> Array[TargetData]:
	var result: Array[TargetData] = []
	var range_squared = range_pixels * range_pixels
	
	for target_data in targets.values():
		if target_data.confidence < min_confidence:
			continue
		
		var distance_squared = center_pos.distance_squared_to(target_data.predicted_position)
		if distance_squared <= range_squared:
			result.append(target_data)
	
	return result

# Get the closest target to a position
func get_closest_target(center_pos: Vector2, max_range: float = INF, 
					   min_confidence: float = 0.0) -> TargetData:
	var closest_target: TargetData = null
	var closest_distance_squared = max_range * max_range
	
	for target_data in targets.values():
		if target_data.confidence < min_confidence:
			continue
		
		var distance_squared = center_pos.distance_squared_to(target_data.predicted_position)
		if distance_squared < closest_distance_squared:
			closest_target = target_data
			closest_distance_squared = distance_squared
	
	return closest_target

# Get all valid targets (for weapon systems)
func get_all_valid_targets() -> Array[TargetData]:
	var result: Array[TargetData] = []
	
	for target_data in targets.values():
		if target_data.is_valid():
			result.append(target_data)
	
	return result

# Get debug information
func get_debug_info() -> String:
	var active_count = 0
	var visual_count = 0
	var sensor_count = 0
	var lost_count = 0
	
	for target_data in targets.values():
		if target_data.is_valid():
			active_count += 1
		
		match target_data.data_source:
			TargetData.DataSource.DIRECT_VISUAL:
				visual_count += 1
			TargetData.DataSource.RADAR_CONTACT, TargetData.DataSource.LIDAR_CONTACT:
				sensor_count += 1
			TargetData.DataSource.LOST_CONTACT:
				lost_count += 1
	
	return "Targets: %d total, %d active (%d visual, %d sensor, %d lost) | Created: %d, Cleaned: %d" % [
		targets.size(), active_count, visual_count, sensor_count, lost_count,
		total_targets_created, total_targets_cleaned
	]
