# Scripts/Systems/SensorSystem.gd - ENTITY SELF-REPORTING RADAR
extends Node2D
class_name SensorSystem

# RADAR SPECIFICATIONS - Now just processes reports
@export var radar_range_meters: float = 250000000.0  # 250,000 km - full map coverage
@export var radar_accuracy: float = 1.0              # Perfect military accuracy
@export var cleanup_interval: float = 1.0            # How often to clean stale contacts

# LEGACY COMPATIBILITY - Keep these exports so old scenes don't crash
@export var radar_update_interval: float = 0.0166667 # Not used anymore, but kept for scene compatibility

# Target tracking - now populated by entity reports
var detected_targets: Dictionary = {}  # entity_id -> DetectedTarget
var parent_ship: Node2D
var ship_faction: int = 1

# Performance tracking
var reports_processed: int = 0
var total_contacts: int = 0
var cleanup_timer: float = 0.0

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
	
	func update_from_report(new_pos: Vector2, new_vel: Vector2):
		position = new_pos
		velocity = new_vel
		last_update_time = Time.get_ticks_msec() / 1000.0
		confidence = 1.0  # Self-reported data is always accurate
	
	func get_age() -> float:
		return Time.get_ticks_msec() / 1000.0 - last_update_time
	
	func is_stale(max_age: float = 10.0) -> bool:
		return get_age() > max_age

func _ready():
	parent_ship = get_parent()
	if parent_ship:
		print("ENTITY-REPORTING RADAR initialized on ship: ", parent_ship.name)
		
		# Get ship faction
		if parent_ship.has_method("_get_faction_type"):
			ship_faction = parent_ship._get_faction_type()
		elif parent_ship.is_in_group("enemy_ships"):
			ship_faction = 2  # Enemy faction
		else:
			ship_faction = 1  # Player faction
		
		print("RADAR faction: ", ship_faction)
		print("RADAR RANGE: ", radar_range_meters / 1000.0, " km")
	else:
		print("ERROR: RADAR has no parent ship!")
	
	# Register this radar system with EntityManager so entities can find us
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		# Add a method to EntityManager to register radar systems
		if entity_manager.has_method("register_radar_system"):
			entity_manager.register_radar_system(self)
		else:
			print("WARNING: EntityManager doesn't support radar registration yet")

func _physics_process(delta):
	cleanup_timer += delta
	
	# Periodic cleanup of stale contacts
	if cleanup_timer >= cleanup_interval:
		cleanup_stale_contacts()
		cleanup_timer = 0.0

# MAIN API: Entities call this to report their position
func receive_entity_report(entity_id: String, entity_pos: Vector2, velocity: Vector2, 
						  entity_type: int, faction_type: int):
	# Check if this entity is within our radar range
	var distance = parent_ship.global_position.distance_to(entity_pos) * WorldSettings.meters_per_pixel
	if distance > radar_range_meters:
		return  # Out of range, ignore
	
	# Update or create detection record
	if detected_targets.has(entity_id):
		# Update existing detection
		var detected = detected_targets[entity_id]
		detected.update_from_report(entity_pos, velocity)
	else:
		# New detection
		var detected = DetectedTarget.new(entity_id, entity_pos, velocity, entity_type, faction_type)
		detected_targets[entity_id] = detected
		
		print("RADAR new contact: ", entity_id, 
			  " (", EntityManager.EntityType.keys()[entity_type], 
			  ", faction ", EntityManager.FactionType.keys()[faction_type], ")")
	
	reports_processed += 1
	
	# Update TargetManager with this detection
	update_target_manager_with_detection(entity_id, entity_pos, velocity)

# Bridge function to update TargetManager
func update_target_manager_with_detection(entity_id: String, entity_pos: Vector2, velocity: Vector2):
	var target_manager = get_node_or_null("/root/TargetManager")
	if not target_manager:
		return
	
	# Entity reports are always high-quality data
	var data_source = TargetData.DataSource.DIRECT_VISUAL
	
	# Try to find the actual node for this entity
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		var entity_data = entity_manager.get_entity(entity_id)
		if entity_data and entity_data.node_ref:
			# Update existing TargetData or register new target
			var target_data = target_manager.get_target_data_for_node(entity_data.node_ref)
			if target_data:
				target_data.update_data(entity_pos, velocity, data_source)
			else:
				target_manager.register_target(entity_data.node_ref, data_source)
		else:
			# Fallback: update by ID
			target_manager.update_target_data(entity_id, entity_pos, velocity, data_source)

func cleanup_stale_contacts():
	var contacts_to_remove = []
	
	for entity_id in detected_targets.keys():
		var detected = detected_targets[entity_id]
		if detected.is_stale(5.0):  # 5 second timeout for entity reports
			contacts_to_remove.append(entity_id)
	
	for entity_id in contacts_to_remove:
		print("RADAR lost contact: ", entity_id)
		detected_targets.erase(entity_id)
	
	total_contacts = detected_targets.size()

# PUBLIC API - Used by weapons and other systems (unchanged)

func get_target_data_for_threats() -> Array[TargetData]:
	var target_manager = get_node_or_null("/root/TargetManager")
	if not target_manager:
		return []
	
	var result: Array[TargetData] = []
	var threats = get_incoming_threats()
	
	for threat in threats:
		var entity_manager = get_node_or_null("/root/EntityManager")
		if entity_manager:
			var entity_data = entity_manager.get_entity(threat.entity_id)
			if entity_data and entity_data.node_ref:
				var target_data = target_manager.get_target_data_for_node(entity_data.node_ref)
				if target_data:
					result.append(target_data)
	
	return result

func get_best_threat_target_data() -> TargetData:
	var target_data_threats = get_target_data_for_threats()
	
	if target_data_threats.is_empty():
		return null
	
	var best_target: TargetData = null
	var best_score = -1.0
	
	for target_data in target_data_threats:
		var distance = parent_ship.global_position.distance_to(target_data.predicted_position)
		var distance_km = distance * WorldSettings.meters_per_pixel / 1000.0
		var speed = target_data.velocity.length()
		
		var threat_score = speed * 10.0 + (50000.0 / (distance_km + 1.0))
		
		if threat_score > best_score:
			best_target = target_data
			best_score = threat_score
	
	return best_target

func get_detected_targets(filter_types: Array[EntityManager.EntityType] = [], 
						 filter_factions: Array[EntityManager.FactionType] = []) -> Array[DetectedTarget]:
	var result: Array[DetectedTarget] = []
	
	for detected in detected_targets.values():
		if filter_types.size() > 0 and detected.entity_type not in filter_types:
			continue
		
		if filter_factions.size() > 0 and detected.faction_type not in filter_factions:
			continue
		
		result.append(detected)
	
	return result

func get_detected_enemies() -> Array[DetectedTarget]:
	var enemy_factions: Array[EntityManager.FactionType] = []
	
	if ship_faction == 1:  # Player ship targets enemies
		enemy_factions = [EntityManager.FactionType.ENEMY]
	elif ship_faction == 2:  # Enemy ship targets players
		enemy_factions = [EntityManager.FactionType.PLAYER]
	else:
		enemy_factions = [EntityManager.FactionType.ENEMY, EntityManager.FactionType.PLAYER]
	
	return get_detected_targets([], enemy_factions)

func get_incoming_threats() -> Array[DetectedTarget]:
	var threat_types: Array[EntityManager.EntityType] = [
		EntityManager.EntityType.TORPEDO,
		EntityManager.EntityType.MISSILE,
		EntityManager.EntityType.PROJECTILE
	]
	
	var enemy_factions: Array[EntityManager.FactionType] = []
	if ship_faction == 1:
		enemy_factions = [EntityManager.FactionType.ENEMY]
	elif ship_faction == 2:
		enemy_factions = [EntityManager.FactionType.PLAYER]
	
	var threats = get_detected_targets(threat_types, enemy_factions)
	
	# All enemy projectiles are immediate threats (same aggressive logic)
	var incoming_threats: Array[DetectedTarget] = []
	
	for threat in threats:
		if is_military_threat(threat):
			incoming_threats.append(threat)
	
	return incoming_threats

func is_military_threat(detected: DetectedTarget) -> bool:
	if not parent_ship:
		return false
	
	var distance_to_target = parent_ship.global_position.distance_to(detected.position) * WorldSettings.meters_per_pixel
	var distance_km = distance_to_target / 1000.0
	
	# Same aggressive threat logic as before
	if distance_km < 50.0:
		return true
	
	if detected.entity_type == EntityManager.EntityType.TORPEDO:
		return true
	
	if detected.entity_type == EntityManager.EntityType.MISSILE:
		return true
	
	if detected.entity_type == EntityManager.EntityType.PROJECTILE:
		var speed_mps = detected.velocity.length()
		if distance_km < 25.0 and speed_mps > 100.0:
			return true
		return false
	
	var threat_velocity = detected.velocity
	if threat_velocity.length() < 10.0:
		return false
	
	var to_us = parent_ship.global_position - detected.position
	var dot_product = threat_velocity.normalized().dot(to_us.normalized())
	
	return dot_product > -0.5

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

func get_debug_info() -> String:
	var threats = get_incoming_threats()
	
	return "ENTITY-REPORTING RADAR: %d contacts, %d threats | Reports: %d | Range: %.0f km" % [
		total_contacts, threats.size(), reports_processed, radar_range_meters / 1000.0
	]
