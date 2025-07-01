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
	var closest_target: Target
