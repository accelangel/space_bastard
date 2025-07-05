# Scripts/Weapons/PDC.gd - DEBUG VERSION
extends Node2D
class_name PDC

@export var max_range_meters: float = 2000.0  # Maximum engagement range
@export var rotation_speed: float = 180.0  # Degrees per second
@export var fire_rate: float = 10.0  # Rounds per second
@export var muzzle_velocity_mps: float = 1200.0  # Bullet velocity in m/s
@export var targeting_lead_time: float = 0.1  # How far ahead to aim

# Preload the bullet scene
@export var bullet_scene: PackedScene

# Node references
@onready var turret_base: Sprite2D = $TurretBase
@onready var barrel: Sprite2D = $TurretBase/Barrel
@onready var muzzle_marker: Marker2D = $TurretBase/Barrel/MuzzlePoint

# Targeting and firing
var current_target: TargetData = null
var target_angle: float = 0.0
var fire_timer: float = 0.0
var entity_id: String
var pdc_faction: int = 1  # Will be set by parent ship
var parent_ship: Node2D = null

# Performance settings
var target_update_interval: float = 0.5  # Slower for debugging
var target_update_timer: float = 0.0

# Debug counters
var debug_frame_count: int = 0
var last_debug_time: float = 0.0

# PDC state
enum PDCState {
	SCANNING,
	TRACKING,
	FIRING,
	RELOADING,
	OFFLINE
}

var current_state: PDCState = PDCState.SCANNING
var scanning_angle: float = 0.0  # For slow scanning rotation
var rest_angle: float = 0.0  # Default forward-facing angle

func _ready():
	print("=== PDC STARTING UP ===")
	
	# Get parent ship reference
	parent_ship = get_parent()
	if parent_ship:
		print("PDC parent ship: ", parent_ship.name)
	else:
		print("PDC parent ship: NULL")

	
	# Determine faction based on parent ship
	if parent_ship:
		if parent_ship.has_method("_get_faction_type"):
			pdc_faction = parent_ship._get_faction_type()
			print("PDC faction from method: ", pdc_faction)
		elif parent_ship.is_in_group("enemy_ships"):
			pdc_faction = 2  # Enemy faction
			print("PDC faction from group (enemy): ", pdc_faction)
		else:
			pdc_faction = 1  # Player faction
			print("PDC faction default (player): ", pdc_faction)
	
	if parent_ship:
		print("PDC initialized with faction: ", pdc_faction, " on ship: ", parent_ship.name)
	else:
		print("PDC initialized with faction: ", pdc_faction, " on ship: unknown")
	
	# If bullet_scene is not assigned, try to load it
	if not bullet_scene:
		bullet_scene = preload("res://Scenes/PDCBullet.tscn")
	if bullet_scene:
		print("PDC loaded bullet scene: true")
	else:
		print("PDC loaded bullet scene: false")
	
	# Check if managers exist
	var entity_manager = get_node_or_null("/root/EntityManager")
	var target_manager = get_node_or_null("/root/TargetManager")
	if entity_manager:
		print("EntityManager exists: true")
	else:
		print("EntityManager exists: false")
	if target_manager:
		print("TargetManager exists: true")
	else:
		print("TargetManager exists: false")
	
	# Register with EntityManager
	if entity_manager:
		entity_id = entity_manager.register_entity(
			self, 
			EntityManager.EntityType.STATION,  # Or create a PDC type
			pdc_faction
		)
		print("PDC registered with EntityManager, ID: ", entity_id)
	
	# Set up fire timer
	fire_timer = 1.0 / fire_rate
	
	# Set initial barrel position to face forward (up)
	rest_angle = deg_to_rad(-90)  # -90 degrees = pointing up
	barrel.rotation = rest_angle
	scanning_angle = rest_angle
	
	print("PDC setup complete, rest angle: ", rad_to_deg(rest_angle))
	print("=== PDC READY ===")

func _physics_process(delta):
	debug_frame_count += 1
	target_update_timer += delta
	fire_timer += delta
	
	# Debug output every 2 seconds
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_time > 2.0:
		print_debug_info()
		last_debug_time = current_time
	
	# Update target search periodically
	if target_update_timer >= target_update_interval:
		update_target_search()
		target_update_timer = 0.0
	
	# Update PDC behavior based on state
	match current_state:
		PDCState.SCANNING:
			handle_scanning(delta)
		PDCState.TRACKING:
			handle_tracking(delta)
		PDCState.FIRING:
			handle_firing(delta)
		PDCState.RELOADING:
			handle_reloading(delta)
		PDCState.OFFLINE:
			handle_offline(delta)

func print_debug_info():
	print("--- PDC DEBUG ---")
	print("State: ", PDCState.keys()[current_state])
	if current_target:
		print("Current target: ", current_target.target_id)
	else:
		print("Current target: NONE")
	print("Faction: ", pdc_faction)
	print("Global position: ", global_position)
	
	# Check for nearby entities manually
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		var range_pixels = max_range_meters / WorldSettings.meters_per_pixel
		print("Search range (pixels): ", range_pixels)
		
		# Get ALL entities nearby
		var all_nearby = entity_manager.get_entities_in_radius(global_position, range_pixels)
		print("All entities in range: ", all_nearby.size())
		
		for entity_data in all_nearby:
			print("  Entity: ", entity_data.entity_id, " Type: ", EntityManager.EntityType.keys()[entity_data.entity_type], " Faction: ", EntityManager.FactionType.keys()[entity_data.faction_type])
		
		# Check specifically for torpedoes
		var torpedoes = entity_manager.get_entities_in_radius(
			global_position, 
			range_pixels,
			[EntityManager.EntityType.TORPEDO],
			[],  # Any faction
			[]   # Any state
		)
		print("Torpedoes in range: ", torpedoes.size())
		
		# Check for enemy torpedoes specifically
		var enemy_factions: Array[EntityManager.FactionType] = []
		if pdc_faction == 1:  # Player PDC targets enemy projectiles
			enemy_factions = [EntityManager.FactionType.ENEMY]
		else:  # Enemy PDC targets player projectiles
			enemy_factions = [EntityManager.FactionType.PLAYER]
		
		var enemy_torpedoes = entity_manager.get_entities_in_radius(
			global_position, 
			range_pixels,
			[EntityManager.EntityType.TORPEDO],
			enemy_factions,
			[]
		)
		print("Enemy torpedoes in range: ", enemy_torpedoes.size())
	
	print("--- END DEBUG ---")

func update_target_search():
	print("PDC updating target search...")
	
	var entity_manager = get_node_or_null("/root/EntityManager")
	var target_manager = get_node_or_null("/root/TargetManager")
	
	if not entity_manager:
		print("ERROR: No EntityManager found!")
		return
	if not target_manager:
		print("ERROR: No TargetManager found!")
		return
	
	var range_pixels = max_range_meters / WorldSettings.meters_per_pixel
	print("PDC search range: ", range_pixels, " pixels (", max_range_meters, " meters)")
	
	# Target incoming torpedoes and missiles
	var threat_entity_types: Array[EntityManager.EntityType] = [
		EntityManager.EntityType.TORPEDO, 
		EntityManager.EntityType.MISSILE
	]
	
	# Target entities from enemy factions only
	var enemy_factions: Array[EntityManager.FactionType] = []
	if pdc_faction == 1:  # Player PDC targets enemy projectiles
		enemy_factions = [EntityManager.FactionType.ENEMY]
	else:  # Enemy PDC targets player projectiles
		enemy_factions = [EntityManager.FactionType.PLAYER]
	
	print("PDC looking for entity types: ", threat_entity_types)
	print("PDC looking for enemy factions: ", enemy_factions)
	
	var exclude_states: Array[EntityManager.EntityState] = [
		EntityManager.EntityState.DESTROYED, 
		EntityManager.EntityState.CLEANUP
	]
	
	var threat_entities = entity_manager.get_entities_in_radius(
		global_position,
		range_pixels,
		threat_entity_types,
		enemy_factions,
		exclude_states
	)
	
	print("Found ", threat_entities.size(), " potential threats")
	
	# Convert to targets and find the closest incoming threat
	var best_target: TargetData = null
	var best_score = -1.0
	
	for entity_data in threat_entities:
		print("Evaluating threat: ", entity_data.entity_id)
		
		# Skip if this is our own entity
		if entity_data.entity_id == entity_id:
			print("  Skipping - own entity")
			continue
		
		# Skip if this entity belongs to our parent ship
		if parent_ship and entity_data.node_ref and entity_data.node_ref.get_parent() == parent_ship:
			print("  Skipping - parent ship entity")
			continue
		
		# Get target data for this entity
		var target_data = target_manager.get_target_data_for_node(entity_data.node_ref)
		if not target_data:
			print("  No target data found, registering...")
			# Try to register it ourselves
			target_data = target_manager.register_target(entity_data.node_ref)
		
		if not target_data:
			print("  ERROR: Could not get target data")
			continue
		
		if not target_data.is_reliable():
			print("  Target data not reliable")
			continue
		
		print("  Target data valid, velocity: ", target_data.velocity)
		
		# Check if projectile is heading towards us (incoming threat)
		var to_pdc = global_position - target_data.predicted_position
		var velocity_normalized: Vector2
		if target_data.velocity.length() > 0:
			velocity_normalized = target_data.velocity.normalized()
		else:
			velocity_normalized = Vector2.ZERO
		
		var dot_product: float
		if to_pdc.length() > 0:
			dot_product = velocity_normalized.dot(to_pdc.normalized())
		else:
			dot_product = 0.0
		
		print("  Dot product (incoming check): ", dot_product)
		
		# RELAXED: Accept any target for debugging
		# if dot_product <= 0.1:  # Allow slight margin for error
		#	print("  Not incoming - dot product too low")
		#	continue
		
		# Calculate threat score (closer and faster = higher threat)
		var distance = global_position.distance_to(target_data.predicted_position)
		var speed = target_data.velocity.length()
		var threat_score = (speed * 0.1) + (1.0 / (distance + 1.0)) * 1000.0
		
		# Bonus for incoming projectiles
		threat_score *= (1.0 + max(0, dot_product))
		
		print("  Threat score: ", threat_score)
		
		if threat_score > best_score:
			best_target = target_data
			best_score = threat_score
			print("  NEW BEST TARGET!")
	
	# Update current target
	if best_target != current_target:
		current_target = best_target
		if current_target:
			print("PDC (faction %d) acquired incoming threat: %s" % [pdc_faction, current_target.target_id])
			current_state = PDCState.TRACKING
		else:
			print("PDC lost target, returning to scanning")
			current_state = PDCState.SCANNING

func handle_scanning(_delta):
	# Stay at rest position when not targeting
	barrel.rotation = rest_angle
	
	# If we found a target, switch to tracking
	if current_target:
		print("PDC switching to TRACKING")
		current_state = PDCState.TRACKING

func handle_tracking(delta):
	if not current_target or not current_target.is_reliable():
		print("PDC lost target reliability, returning to scanning")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Calculate intercept point
	var intercept_point = calculate_intercept_point()
	if intercept_point == Vector2.ZERO:
		print("PDC can't calculate intercept, returning to scanning")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	print("PDC tracking, intercept point: ", intercept_point)
	
	# Calculate desired barrel angle
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var desired_angle = direction_to_intercept.angle() - global_rotation
	
	# Rotate barrel towards intercept point
	var angle_diff = angle_difference(barrel.rotation, desired_angle)
	var max_rotation = deg_to_rad(rotation_speed) * delta
	
	print("PDC angle diff: ", rad_to_deg(angle_diff), " degrees")
	
	if abs(angle_diff) > max_rotation:
		barrel.rotation += sign(angle_diff) * max_rotation
	else:
		barrel.rotation = desired_angle
		
		# If we're aimed correctly, start firing
		if abs(angle_diff) < deg_to_rad(15.0):  # More lenient for debugging
			print("PDC switching to FIRING")
			current_state = PDCState.FIRING

func handle_firing(_delta):
	if not current_target or not current_target.is_reliable():
		print("PDC lost target during firing, returning to scanning")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Check if we're still aimed correctly
	var intercept_point = calculate_intercept_point()
	if intercept_point == Vector2.ZERO:
		print("PDC lost intercept during firing, returning to tracking")
		current_state = PDCState.TRACKING
		return
	
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var desired_angle = direction_to_intercept.angle() - global_rotation
	var angle_diff = angle_difference(barrel.rotation, desired_angle)
	
	if abs(angle_diff) > deg_to_rad(20.0):  # More lenient for debugging
		print("PDC lost aim during firing, returning to tracking")
		current_state = PDCState.TRACKING
		return
	
	# Fire if ready and we have a bullet scene
	if fire_timer >= (1.0 / fire_rate) and bullet_scene:
		print("PDC FIRING BULLET!")
		fire_bullet()
		fire_timer = 0.0

func handle_reloading(_delta):
	# For now, just switch back to scanning after a brief pause
	if fire_timer >= 0.5:  # Half second reload
		current_state = PDCState.SCANNING

func handle_offline(_delta):
	# PDC is offline - do nothing
	pass

func calculate_intercept_point() -> Vector2:
	if not current_target:
		return Vector2.ZERO
	
	var target_pos = current_target.predicted_position
	var target_vel = current_target.velocity
	var _bullet_speed = muzzle_velocity_mps / WorldSettings.meters_per_pixel
	
	# Simple intercept calculation
	var _relative_pos = target_pos - global_position
	var _relative_vel = target_vel
	
	# For debugging, just aim slightly ahead
	return target_pos + target_vel * 0.5  # Aim 0.5 seconds ahead

func fire_bullet():
	if not bullet_scene:
		print("Error: PDC bullet_scene is null! Cannot fire.")
		return
	
	# Create bullet
	var bullet = bullet_scene.instantiate()
	if not bullet:
		print("Error: Failed to instantiate bullet from scene!")
		return
	
	# Add bullet to the main scene
	get_tree().root.add_child(bullet)
	
	# Position bullet at muzzle
	var muzzle_global_pos = muzzle_marker.global_position
	bullet.global_position = muzzle_global_pos
	
	# Calculate bullet direction
	var intercept_point = calculate_intercept_point()
	var bullet_direction = Vector2.RIGHT.rotated(barrel.global_rotation)
	
	if intercept_point != Vector2.ZERO:
		bullet_direction = (intercept_point - muzzle_global_pos).normalized()
	
	# Set bullet velocity
	if bullet.has_method("set_velocity"):
		var bullet_vel_pixels = bullet_direction * (muzzle_velocity_mps / WorldSettings.meters_per_pixel)
		bullet.set_velocity(bullet_vel_pixels)
	
	# Set bullet faction to match PDC
	if bullet.has_method("set_faction"):
		bullet.set_faction(pdc_faction)
	
	if current_target:
		print("PDC (faction %d) fired at incoming threat: %s" % [pdc_faction, current_target.target_id])
	else:
		print("PDC (faction %d) fired at incoming threat: none" % [pdc_faction])

func set_offline(offline: bool):
	if offline:
		current_state = PDCState.OFFLINE
		current_target = null
	else:
		current_state = PDCState.SCANNING

func get_debug_info() -> String:
	var state_name = PDCState.keys()[current_state]
	var target_name: String
	if current_target:
		target_name = current_target.target_id
	else:
		target_name = "none"
	return "PDC [%s] Faction: %d Target: %s | Angle: %.1f°" % [state_name, pdc_faction, target_name, rad_to_deg(barrel.rotation)]
