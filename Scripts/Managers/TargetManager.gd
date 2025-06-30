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

func _process(delta):
	cleanup_timer += delta
	
	# Update all target positions every frame
	update_all_targets()
	
	# Update all target data age and confidence
	for target_data in targets.values():
		target_data.update_age_and_confidence()
	
	# Periodic cleanup
	if cleanup_timer >= cleanup_interval:
		cleanup_stale_targets()
		cleanup_timer = 0.0

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
	var closest_distance: float = INF
	
	for target_data in targets.values():
		if target_data.confidence < min_confidence:
			continue
		
		var distance = center_pos.distance_to(target_data.predicted_position)
		if distance < closest_distance and distance <= max_range:
			closest_distance = distance
			closest_target = target_data
	
	return closest_target

# Remove a target by ID
func remove_target(target_id: String) -> bool:
	if not targets.has(target_id):
		return false
	
	var target_data = targets[target_id]
	
	# Remove from entity lookup if node exists
	if target_data.target_node and entity_to_target_id.has(target_data.target_node):
		entity_to_target_id.erase(target_data.target_node)
	
	targets.erase(target_id)
	print("Removed target: ", target_id)
	return true

# Remove target by node reference
func remove_target_for_node(node: Node2D) -> bool:
	if not entity_to_target_id.has(node):
		return false
	
	var target_id = entity_to_target_id[node]
	return remove_target(target_id)

# Handle when a node is removed from the scene
func _on_node_removed(node: Node):
	if entity_to_target_id.has(node):
		var target_id = entity_to_target_id[node]
		print("Node removed from scene, cleaning up target: ", target_id)
		remove_target(target_id)

# Clean up stale and invalid targets
func cleanup_stale_targets():
	var targets_to_remove: Array[String] = []
	
	for target_id in targets.keys():
		var target_data = targets[target_id]
		
		# Check if target node is still valid
		if not target_data.validate_target_node():
			targets_to_remove.append(target_id)
			continue
		
		# Check if data is too old or confidence too low
		if not target_data.is_valid():
			targets_to_remove.append(target_id)
			continue
	
	# Remove stale targets
	for target_id in targets_to_remove:
		remove_target(target_id)
		total_targets_cleaned += 1
	
	if targets_to_remove.size() > 0:
		print("Cleaned up ", targets_to_remove.size(), " stale targets")

# Auto-register all ships in specified groups
func auto_register_group(group_name: String, data_source: TargetData.DataSource = TargetData.DataSource.DIRECT_VISUAL):
	var nodes = get_tree().get_nodes_in_group(group_name)
	var registered_count = 0
	
	for node in nodes:
		if node is Node2D:
			register_target(node, data_source)
			registered_count += 1
	
	print("Auto-registered ", registered_count, " targets from group: ", group_name)

# Debug functions
func get_target_count() -> int:
	return targets.size()

func print_all_targets():
	print("=== TARGET MANAGER STATUS ===")
	print("Active targets: ", targets.size())
	print("Total created: ", total_targets_created)
	print("Total cleaned: ", total_targets_cleaned)
	
	for target_data in targets.values():
		print("  ", target_data.get_debug_info())
	print("============================")

# Get statistics for UI display
func get_statistics() -> Dictionary:
	var reliable_targets = 0
	var stale_targets = 0
	var lost_targets = 0
	
	for target_data in targets.values():
		if target_data.is_reliable():
			reliable_targets += 1
		elif target_data.data_source == TargetData.DataSource.LOST_CONTACT:
			lost_targets += 1
		else:
			stale_targets += 1
	
	return {
		"total": targets.size(),
		"reliable": reliable_targets,
		"stale": stale_targets,
		"lost": lost_targets,
		"created": total_targets_created,
		"cleaned": total_targets_cleaned
	}

# Update all targets with current node positions (call this every frame)
func update_all_targets():
	for target_id in targets.keys():
		var target_data = targets[target_id]
		
		# Skip if node is invalid
		if not target_data.validate_target_node():
			continue
		
		# Get current position and calculate velocity
		var current_pos = target_data.target_node.global_position
		var current_vel = Vector2.ZERO
		
		# Try to get velocity from the ship if it has one
		if target_data.target_node.has_method("get_velocity_mps"):
			current_vel = target_data.target_node.get_velocity_mps()
		elif "velocity_mps" in target_data.target_node:
			current_vel = target_data.target_node.velocity_mps
		
		# Update the target data with fresh information
		target_data.update_data(current_pos, current_vel, TargetData.DataSource.DIRECT_VISUAL)
