# Scripts/Weapons/PDC.gd - FIXED VERSION
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
var target_update_interval: float = 0.1  # How often to search for targets
var target_update_timer: float = 0.0

# PDC state
enum PDCState {
	SCANNING,
	TRACKING,
	FIRING,
	RELOADING,
	OFFLINE
}

var current_state: PDCState = PDCState.SCANNING

func _ready():
	# Get parent ship reference
	parent_ship = get_parent()
	
	# Determine faction based on parent ship
	if parent_ship:
		if parent_ship.has_method("_get_faction_type"):
			pdc_faction = parent_ship._get_faction_type()
		elif parent_ship.is_in_group("enemy_ships"):
			pdc_faction = 2  # Enemy faction
		else:
			pdc_faction = 1  # Player faction
	
	print("PDC initialized with faction: ", pdc_faction, " on ship: ", str(parent_ship.name) if parent_ship else "unknown")
	
	# If bullet_scene is not assigned, try to load it
	if not bullet_scene:
		bullet_scene = preload("res://Scenes/PDCBullet.tscn")
	
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(
			self, 
			EntityManager.EntityType.STATION,  # Or create a PDC type
			pdc_faction
		)
	
	# Set up fire timer
	fire_timer = 1.0 / fire_rate
	
	# Make sure we have a bullet scene
	if not bullet_scene:
		print("Warning: PDC has no bullet scene assigned!")

func _physics_process(delta):
	target_update_timer += delta
	fire_timer += delta
	
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

func update_target_search():
	var entity_manager = get_node_or_null("/root/EntityManager")
	var target_manager = get_node_or_null("/root/TargetManager")
	
	if not entity_manager or not target_manager:
		return
	
	var range_pixels = max_range_meters / WorldSettings.meters_per_pixel
	
	# FIXED: Only target incoming torpedoes and missiles, not ships
	var threat_entity_types: Array[EntityManager.EntityType] = [
		EntityManager.EntityType.TORPEDO, 
		EntityManager.EntityType.MISSILE
	]
	
	# FIXED: Target entities from enemy factions only
	var enemy_factions: Array[EntityManager.FactionType] = []
	if pdc_faction == 1:  # Player PDC targets enemy projectiles
		enemy_factions = [EntityManager.FactionType.ENEMY]
	else:  # Enemy PDC targets player projectiles
		enemy_factions = [EntityManager.FactionType.PLAYER]
	
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
	
	# Convert to targets and find the closest incoming threat
	var best_target: TargetData = null
	var best_score = -1.0
	
	for entity_data in threat_entities:
		# Skip if this is our own entity
		if entity_data.entity_id == entity_id:
			continue
		
		# Skip if this entity belongs to our parent ship
		if parent_ship and entity_data.node_ref and entity_data.node_ref.get_parent() == parent_ship:
			continue
		
		# Get target data for this entity
		var target_data = target_manager.get_target_data_for_node(entity_data.node_ref)
		if not target_data or not target_data.is_reliable():
			continue
		
		# Check if projectile is heading towards us (incoming threat)
		var to_pdc = global_position - target_data.predicted_position
		var dot_product = target_data.velocity.normalized().dot(to_pdc.normalized())
		
		# Only engage if projectile is moving towards us (dot product > 0)
		if dot_product <= 0.1:  # Allow slight margin for error
			continue
		
		# Calculate threat score (closer and faster = higher threat)
		var distance = global_position.distance_to(target_data.predicted_position)
		var speed = target_data.velocity.length()
		var threat_score = (speed * 0.1) + (1.0 / (distance + 1.0)) * 1000.0
		
		# Bonus for incoming projectiles
		threat_score *= (1.0 + dot_product)
		
		if threat_score > best_score:
			best_target = target_data
			best_score = threat_score
	
	# Update current target
	if best_target != current_target:
		current_target = best_target
		if current_target:
			print("PDC (faction %d) acquired incoming threat: %s" % [pdc_faction, current_target.target_id])
			current_state = PDCState.TRACKING
		else:
			current_state = PDCState.SCANNING

func handle_scanning(delta):
	# Slowly rotate while scanning
	barrel.rotation += deg_to_rad(rotation_speed * 0.2) * delta
	
	# If we found a target, switch to tracking
	if current_target:
		current_state = PDCState.TRACKING

func handle_tracking(delta):
	if not current_target or not current_target.is_reliable():
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Calculate intercept point
	var intercept_point = calculate_intercept_point()
	if intercept_point == Vector2.ZERO:
		# Can't intercept - target too fast or unpredictable
		current_state = PDCState.SCANNING
		return
	
	# Calculate desired barrel angle
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var desired_angle = direction_to_intercept.angle() - global_rotation
	
	# Rotate barrel towards intercept point
	var angle_diff = angle_difference(barrel.rotation, desired_angle)
	var max_rotation = deg_to_rad(rotation_speed) * delta
	
	if abs(angle_diff) > max_rotation:
		barrel.rotation += sign(angle_diff) * max_rotation
	else:
		barrel.rotation = desired_angle
		
		# If we're aimed correctly, start firing
		if abs(angle_diff) < deg_to_rad(5.0):  # Within 5 degrees
			current_state = PDCState.FIRING

func handle_firing(_delta):
	if not current_target or not current_target.is_reliable():
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Check if we're still aimed correctly
	var intercept_point = calculate_intercept_point()
	if intercept_point == Vector2.ZERO:
		current_state = PDCState.TRACKING
		return
	
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var desired_angle = direction_to_intercept.angle() - global_rotation
	var angle_diff = angle_difference(barrel.rotation, desired_angle)
	
	if abs(angle_diff) > deg_to_rad(10.0):  # Lost target accuracy
		current_state = PDCState.TRACKING
		return
	
	# Fire if ready
	if fire_timer >= (1.0 / fire_rate):
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
	var bullet_speed = muzzle_velocity_mps / WorldSettings.meters_per_pixel
	
	# Simple intercept calculation
	var relative_pos = target_pos - global_position
	var relative_vel = target_vel
	
	# Solve for intercept time using quadratic formula
	var a = relative_vel.dot(relative_vel) - bullet_speed * bullet_speed
	var b = 2.0 * relative_pos.dot(relative_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	if discriminant < 0 or abs(a) < 0.001:
		# No intercept solution or target too fast
		return Vector2.ZERO
	
	var t1 = (-b - sqrt(discriminant)) / (2.0 * a)
	var t2 = (-b + sqrt(discriminant)) / (2.0 * a)
	
	var intercept_time = t1 if t1 > 0 else t2
	if intercept_time <= 0:
		return Vector2.ZERO
	
	# Calculate intercept point
	return target_pos + target_vel * intercept_time

func fire_bullet():
	if not bullet_scene:
		print("Error: PDC bullet_scene is null! Cannot fire.")
		return
	
	# Create bullet
	var bullet = bullet_scene.instantiate()
	if not bullet:
		print("Error: Failed to instantiate bullet from scene!")
		return
	
	get_tree().current_scene.add_child(bullet)
	
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
	
	# FIXED: Set bullet faction to match PDC
	if bullet.has_method("set_faction"):
		bullet.set_faction(pdc_faction)
	
	print("PDC (faction %d) fired at incoming threat: %s" % [pdc_faction, current_target.target_id if current_target else "none"])

func set_offline(offline: bool):
	if offline:
		current_state = PDCState.OFFLINE
		current_target = null
	else:
		current_state = PDCState.SCANNING

func get_debug_info() -> String:
	var state_name = PDCState.keys()[current_state]
	var target_name = current_target.target_id if current_target else "none"
	return "PDC [%s] Faction: %d Target: %s | Angle: %.1f°" % [state_name, pdc_faction, target_name, rad_to_deg(barrel.rotation)]
