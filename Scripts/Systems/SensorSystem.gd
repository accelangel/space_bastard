# Scripts/Systems/SensorSystem.gd - UPDATED for Full Integration
extends Node2D
class_name SensorSystem

# Radar specifications
@export var radar_range_meters: float = 5000.0  # Detection range
@export var radar_update_interval: float = 0.5   # Seconds between scans
@export var radar_accuracy: float = 0.95         # Base accuracy (0.0 to 1.0)

# Target tracking
var detected_targets: Dictionary = {}  # entity_id -> DetectedTarget
var radar_update_timer: float = 0.0
var parent_ship: Node2D
var ship_faction: int = 1  # Will be set by parent ship

# Performance tracking
var last_scan_count: int = 0
var total_scans: int = 0

class DetectedTarget:
	var entity_id: String
	var position: Vector2
	var velocity: Vector2
	var detection_time: float
	var last_update_time: float
	var confidence: float = 1.0
	var entity_type: int
	var faction_type: int
	
	func _init(id: String, pos: Vector2, vel: Vector2, ent_type: int, fact_type: int):
		entity_id = id
		position = pos
		velocity = vel
		entity_type = ent_type
		faction_type = fact_type
		detection_time = Time.get_ticks_msec() / 1000.0
		last_update_time = detection_time
	
	func update_detection(new_pos: Vector2, new_vel: Vector2, accuracy: float):
		position = new_pos
		velocity = new_vel
		last_update_time = Time.get_ticks_msec() / 1000.0
		confidence = accuracy
	
	func get_age() -> float:
		return Time.get_ticks_msec() / 1000.0 - last_update_time
	
	func is_stale(max_age: float = 10.0) -> bool:
		return get_age() > max_age

func _ready():
	parent_ship = get_parent()
	if parent_ship:
		print("SensorSystem initialized on ship: ", parent_ship.name)
		
		# Get ship faction
		if parent_ship.has_method("_get_faction_type"):
			ship_faction = parent_ship._get_faction_type()
		elif parent_ship.is_in_group("enemy_ships"):
			ship_faction = 2  # Enemy faction
		else:
			ship_faction = 1  # Player faction
		
		print("SensorSystem faction: ", ship_faction)
	else:
		print("ERROR: SensorSystem has no parent ship!")

func _physics_process(delta):
	radar_update_timer += delta
	
	# Update target data age and remove stale targets
	update_target_tracking()
	
	# Perform radar scan
	if radar_update_timer >= radar_update_interval:
		perform_radar_scan()
		radar_update_timer = 0.0

func perform_radar_scan():
	if not parent_ship:
		return
	
	var entity_manager = get_node_or_null("/root/EntityManager")
	var target_manager = get_node_or_null("/root/TargetManager")
	
	if not entity_manager:
		print("ERROR: No EntityManager found for radar scan!")
		return
	
	if not target_manager:
		print("ERROR: No TargetManager found for radar scan!")
		return
	
	var range_pixels = radar_range_meters / WorldSettings.meters_per_pixel
	var scan_center = parent_ship.global_position
	
	# Define what we want to detect based on our faction
	var target_types: Array[EntityManager.EntityType] = [
		EntityManager.EntityType.TORPEDO,
		EntityManager.EntityType.MISSILE,
		EntityManager.EntityType.PROJECTILE,
		EntityManager.EntityType.PLAYER_SHIP,
		EntityManager.EntityType.ENEMY_SHIP,
		EntityManager.EntityType.NEUTRAL_SHIP
	]
	
	# We detect all factions (but weapons will filter by enemy/friendly)
	var all_factions: Array[EntityManager.FactionType] = []
	
	var exclude_states: Array[EntityManager.EntityState] = [
		EntityManager.EntityState.DESTROYED,
		EntityManager.EntityState.CLEANUP
	]
	
	# Perform the scan
	var detected_entities = entity_manager.get_entities_in_radius(
		scan_center,
		range_pixels,
		target_types,
		all_factions,
		exclude_states
	)
	
	last_scan_count = detected_entities.size()
	total_scans += 1
	
	# Process detected entities and register with TargetManager
	for entity_data in detected_entities:
		# Skip our own ship
		if entity_data.node_ref == parent_ship:
			continue
		
		# Skip entities that belong to our ship (our own weapons)
		if entity_data.owner_id and entity_data.owner_id.begins_with(parent_ship.name):
			continue
		
		# Update or create detection record
		if detected_targets.has(entity_data.entity_id):
			# Update existing detection
			var detected = detected_targets[entity_data.entity_id]
			detected.update_detection(entity_data.position, entity_data.velocity, radar_accuracy)
		else:
			# New detection
			var detected = DetectedTarget.new(
				entity_data.entity_id,
				entity_data.position,
				entity_data.velocity,
				entity_data.entity_type,
				entity_data.faction_type
			)
			detected_targets[entity_data.entity_id] = detected
			
			print("Radar detected new target: ", entity_data.entity_id, 
				  " (", EntityManager.EntityType.keys()[entity_data.entity_type], 
				  ", faction ", EntityManager.FactionType.keys()[entity_data.faction_type], ")")
		
		# CRITICAL: Register/update this target with TargetManager
		# This bridges SensorSystem detections to TargetData that weapons can use
		update_target_manager_with_detection(entity_data, target_manager)

# NEW: Bridge function to update TargetManager with our sensor data
func update_target_manager_with_detection(entity_data, target_manager):
	var detected = detected_targets[entity_data.entity_id]
	
	# Determine data source based on detection quality and range
	var data_source = TargetData.DataSource.RADAR_CONTACT
	if detected.confidence >= 1.0:
		data_source = TargetData.DataSource.RADAR_CONTACT  # High quality sensor data
	elif detected.confidence >= 0.8:
		data_source = TargetData.DataSource.RADAR_CONTACT
	else:
		data_source = TargetData.DataSource.ESTIMATED
	
	# If we have direct visual (node reference is valid), use that instead
	if entity_data.node_ref and is_instance_valid(entity_data.node_ref):
		# For very close targets or clear sensor readings, use direct visual
		var distance_meters = parent_ship.global_position.distance_to(entity_data.position) * WorldSettings.meters_per_pixel
		if distance_meters < 500.0 or detected.confidence >= 0.98:
			data_source = TargetData.DataSource.DIRECT_VISUAL
	
	# Update TargetManager with this detection
	if entity_data.node_ref:
		# Try to get existing TargetData
		var target_data = target_manager.get_target_data_for_node(entity_data.node_ref)
		
		if target_data:
			# Update existing target data
			target_data.update_data(detected.position, detected.velocity, data_source)
		else:
			# Register new target
			target_manager.register_target(entity_data.node_ref, data_source)
	else:
		# Node reference lost, but we can still update by ID if it exists
		target_manager.update_target_data(
			entity_data.entity_id,
			detected.position,
			detected.velocity,
			data_source
		)

func update_target_tracking():
	# Remove stale targets
	var targets_to_remove = []
	
	for entity_id in detected_targets.keys():
		var detected = detected_targets[entity_id]
		if detected.is_stale(15.0):  # 15 second timeout
			targets_to_remove.append(entity_id)
	
	for entity_id in targets_to_remove:
		print("Radar lost contact with: ", entity_id)
		detected_targets.erase(entity_id)

# PUBLIC API - Used by weapons and other systems

# NEW: Get TargetData objects for weapons to use
func get_target_data_for_threats() -> Array[TargetData]:
	var target_manager = get_node_or_null("/root/TargetManager")
	if not target_manager:
		return []
	
	var result: Array[TargetData] = []
	var threats = get_incoming_threats()
	
	for threat in threats:
		# Try to find corresponding TargetData
		var entity_manager = get_node_or_null("/root/EntityManager")
		if entity_manager:
			var entity_data = entity_manager.get_entity(threat.entity_id)
			if entity_data and entity_data.node_ref:
				var target_data = target_manager.get_target_data_for_node(entity_data.node_ref)
				if target_data:
					result.append(target_data)
	
	return result

# NEW: Get best threat target as TargetData for PDC systems
func get_best_threat_target_data() -> TargetData:
	var target_data_threats = get_target_data_for_threats()
	
	if target_data_threats.is_empty():
		return null
	
	# Find closest incoming threat
	var best_target: TargetData = null
	var best_score = -1.0
	
	for target_data in target_data_threats:
		if not target_data.is_reliable():
			continue
		
		# Score based on distance and threat level
		var distance = parent_ship.global_position.distance_to(target_data.predicted_position)
		var speed = target_data.velocity.length()
		var threat_score = (speed * 0.1) + (1.0 / (distance + 1.0)) * 1000.0
		
		if threat_score > best_score:
			best_target = target_data
			best_score = threat_score
	
	return best_target

# Get all detected targets (optionally filtered)
func get_detected_targets(filter_types: Array[EntityManager.EntityType] = [], 
						 filter_factions: Array[EntityManager.FactionType] = []) -> Array[DetectedTarget]:
	var result: Array[DetectedTarget] = []
	
	for detected in detected_targets.values():
		# Filter by type if specified
		if filter_types.size() > 0 and detected.entity_type not in filter_types:
			continue
		
		# Filter by faction if specified
		if filter_factions.size() > 0 and detected.faction_type not in filter_factions:
			continue
		
		result.append(detected)
	
	return result

# Get detected enemies (based on our faction)
func get_detected_enemies() -> Array[DetectedTarget]:
	var enemy_factions: Array[EntityManager.FactionType] = []
	
	if ship_faction == 1:  # Player ship targets enemies
		enemy_factions = [EntityManager.FactionType.ENEMY]
	elif ship_faction == 2:  # Enemy ship targets players
		enemy_factions = [EntityManager.FactionType.PLAYER]
	else:  # Neutral targets everyone? Or no one?
		enemy_factions = [EntityManager.FactionType.ENEMY, EntityManager.FactionType.PLAYER]
	
	return get_detected_targets([], enemy_factions)

# Get detected incoming threats (enemy projectiles)
func get_incoming_threats() -> Array[DetectedTarget]:
	var threat_types: Array[EntityManager.EntityType] = [
		EntityManager.EntityType.TORPEDO,
		EntityManager.EntityType.MISSILE,
		EntityManager.EntityType.PROJECTILE
	]
	
	var enemy_factions: Array[EntityManager.FactionType] = []
	if ship_faction == 1:  # Player ship
		enemy_factions = [EntityManager.FactionType.ENEMY]
	elif ship_faction == 2:  # Enemy ship
		enemy_factions = [EntityManager.FactionType.PLAYER]
	
	var threats = get_detected_targets(threat_types, enemy_factions)
	
	# Additional filtering: only return threats that are actually heading toward us
	var incoming_threats: Array[DetectedTarget] = []
	
	for threat in threats:
		if is_threat_incoming(threat):
			incoming_threats.append(threat)
	
	return incoming_threats

# Check if a detected target is heading toward our ship
func is_threat_incoming(detected: DetectedTarget) -> bool:
	if not parent_ship:
		return false
	
	# Simple check: is the threat moving in our general direction?
	var to_us = parent_ship.global_position - detected.position
	var threat_velocity = detected.velocity
	
	if threat_velocity.length() < 10.0:  # Very slow or stationary
		return false
	
	# Check if velocity vector points toward us (dot product > 0)
	var dot_product = threat_velocity.normalized().dot(to_us.normalized())
	
	# Allow some margin for error (0.3 is about 70 degrees cone)
	return dot_product > 0.3

# Get closest threat to our ship
func get_closest_threat() -> DetectedTarget:
	if not parent_ship:
		return null
	
	var threats = get_incoming_threats()
	if threats.is_empty():
		return null
	
	var closest: DetectedTarget = null
	var closest_distance_sq = INF
	
	for threat in threats:
		var distance_sq = parent_ship.global_position.distance_squared_to(threat.position)
		if distance_sq < closest_distance_sq:
			closest = threat
			closest_distance_sq = distance_sq
	
	return closest

# Get targets within a specific range
func get_targets_in_range(center: Vector2, range_meters: float, 
						 filter_types: Array[EntityManager.EntityType] = [], 
						 filter_factions: Array[EntityManager.FactionType] = []) -> Array[DetectedTarget]:
	var range_pixels = range_meters / WorldSettings.meters_per_pixel
	var range_sq = range_pixels * range_pixels
	var result: Array[DetectedTarget] = []
	
	var all_targets = get_detected_targets(filter_types, filter_factions)
	
	for target in all_targets:
		var distance_sq = center.distance_squared_to(target.position)
		if distance_sq <= range_sq:
			result.append(target)
	
	return result

# Debug information
func get_debug_info() -> String:
	var threats = get_incoming_threats()
	var all_contacts = detected_targets.size()
	
	return "Radar: %d contacts, %d threats | Range: %.0fm | Scans: %d" % [
		all_contacts, threats.size(), radar_range_meters, total_scans
	]
