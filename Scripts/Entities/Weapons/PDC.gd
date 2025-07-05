# Scripts/Weapons/PDC.gd
extends Node2D
class_name PDC

@export var max_range_meters: float = 2000.0  # Maximum engagement range
@export var rotation_speed: float = 180.0  # Degrees per second
@export var fire_rate: float = 10.0  # Rounds per second
@export var muzzle_velocity_mps: float = 1200.0  # Bullet velocity in m/s
@export var targeting_lead_time: float = 0.1  # How far ahead to aim
@export var faction_type: int = 1  # FactionType.PLAYER by default

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
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(
			self, 
			EntityManager.EntityType.STATION,  # Or create a PDC type
			faction_type
		)
	
	# Set up fire timer
	fire_timer = 1.0 / fire_rate
	
	# Make sure we have a bullet scene
	if not bullet_scene:
		print("Warning: PDC has no bullet scene assigned!")
	
	print("PDC initialized - Range: ", max_range_meters, "m, Fire rate: ", fire_rate, " rps")

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
	
	# Look for enemy entities first (using EntityManager)
	var enemy_entities = entity_manager.get_entities_in_radius(
		global_position,
		range_pixels,
		[EntityManager.EntityType.ENEMY_SHIP, EntityManager.EntityType.TORPEDO, EntityManager.EntityType.MISSILE],
		[EntityManager.FactionType.ENEMY],
		[EntityManager.EntityState.DESTROYED, EntityManager.EntityState.CLEANUP]
	)
	
	# Convert to targets and find the closest threat
	var best_target: TargetData = null
	var best_score = -1.0
	
	for entity_data in enemy_entities:
		# Get target data for this entity
		var target_data = target_manager.get_target_data_for_node(entity_data.node_ref)
		if not target_data or not target_data.is_reliable():
			continue
		
		# Calculate threat score (closer and faster = higher threat)
		var distance = global_position.distance_to(target_data.predicted_position)
		var speed = target_data.velocity.length()
		var threat_score = (speed * 0.1) + (1.0 / (distance + 1.0)) * 1000.0
		
		if threat_score > best_score:
			best_target = target_data
			best_score = threat_score
	
	# Update current target
	if best_target != current_target:
		current_target = best_target
		if current_target:
			print("PDC acquired target: ", current_target.target_id)
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

func handle_firing(delta):
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

func handle_reloading(delta):
	# For now, just switch back to scanning after a brief pause
	if fire_timer >= 0.5:  # Half second reload
		current_state = PDCState.SCANNING

func handle_offline(delta):
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
		print("PDC cannot fire - no bullet scene!")
		return
	
	# Create bullet
	var bullet = bullet_scene.instantiate()
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
	
	# Set bullet faction
	if bullet.has_method("set_faction"):
		bullet.set_faction(faction_type)
	
	print("PDC fired at target: ", current_target.target_id if current_target else "none")

func set_offline(offline: bool):
	if offline:
		current_state = PDCState.OFFLINE
		current_target = null
	else:
		current_state = PDCState.SCANNING

func get_debug_info() -> String:
	var state_name = PDCState.keys()[current_state]
	var target_name = current_target.target_id if current_target else "none"
	return "PDC [%s] Target: %s | Angle: %.1f°" % [state_name, target_name, rad_to_deg(barrel.rotation)]
