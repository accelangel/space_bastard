# Scripts/Weapons/PDC.gd - FIXED ANGLE AND SPEED VERSION
extends Node2D
class_name PDC

# DEFENSIVE SPECIFICATIONS - More reasonable values
@export var max_range_meters: float = 15000.0    # 15km engagement range (more reasonable)
@export var optimal_range_meters: float = 8000.0 # 8km optimal engagement
@export var rotation_speed: float = 180.0        # Degrees per second - still fast but reasonable
@export var fire_rate: float = 10.0              # 10 rounds per second - more reasonable
@export var muzzle_velocity_mps: float = 800.0   # 800 m/s bullet velocity (much more reasonable)
@export var targeting_lead_time: float = 1.0     # Lead targets by 1 second

# Defensive fire patterns
@export var burst_fire_mode: bool = true         
@export var burst_size: int = 5                  # Smaller bursts
@export var burst_spread_degrees: float = 2.0    # Tighter spread

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
var burst_counter: int = 0
var entity_id: String
var pdc_faction: int = 1  # Will be set by parent ship
var parent_ship: Node2D = null

# Ship's sensor system reference
var ship_sensor_system: SensorSystem = null

# Performance settings
var target_update_interval: float = 0.2  # Slower target updates
var target_update_timer: float = 0.0

# Debug counters
var debug_frame_count: int = 0
var last_debug_time: float = 0.0
var shots_fired: int = 0

# PDC state
enum PDCState {
	SCANNING,
	TRACKING,
	FIRING,
	BURST_FIRING,
	RELOADING,
	OFFLINE
}

var current_state: PDCState = PDCState.SCANNING
var scanning_angle: float = 0.0
var rest_angle: float = 0.0

func _ready():
	print("=== PDC STARTING UP (FIXED VERSION) ===")
	
	# Get parent ship reference
	parent_ship = get_parent()
	if parent_ship:
		print("PDC parent ship: ", parent_ship.name)
		
		# Find the ship's sensor system
		ship_sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if ship_sensor_system:
			print("PDC found sensor system: ", ship_sensor_system.name)
		else:
			print("ERROR: PDC could not find ship sensor system!")
	else:
		print("ERROR: PDC has no parent ship!")
	
	# Determine faction based on parent ship
	if parent_ship:
		if parent_ship.has_method("_get_faction_type"):
			pdc_faction = parent_ship._get_faction_type()
		elif parent_ship.is_in_group("enemy_ships"):
			pdc_faction = 2  # Enemy faction
		else:
			pdc_faction = 1  # Player faction
	
	print("PDC initialized with faction: ", pdc_faction)
	print("PDC ENGAGEMENT RANGE: ", max_range_meters / 1000.0, " km")
	print("PDC MUZZLE VELOCITY: ", muzzle_velocity_mps, " m/s")
	
	# If bullet_scene is not assigned, try to load it
	if not bullet_scene:
		bullet_scene = preload("res://Scenes/PDCBullet.tscn")
	
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(
			self, 
			EntityManager.EntityType.STATION,
			pdc_faction
		)
		print("PDC registered with EntityManager, ID: ", entity_id)
	
	# Set up fire timer
	fire_timer = 1.0 / fire_rate
	
	# FIXED: Set initial barrel position to face forward relative to ship
	rest_angle = 0.0  # 0 degrees = pointing forward relative to ship
	barrel.rotation = rest_angle
	scanning_angle = rest_angle
	
	print("PDC setup complete, engagement ready")

func _physics_process(delta):
	debug_frame_count += 1
	target_update_timer += delta
	fire_timer += delta
	
	# Debug output every 5 seconds (less spam)
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_time > 5.0:
		print_debug_info()
		last_debug_time = current_time
	
	# Update target search periodically
	if target_update_timer >= target_update_interval:
		update_target_from_sensors()
		target_update_timer = 0.0
	
	# Update PDC behavior based on state
	match current_state:
		PDCState.SCANNING:
			handle_scanning(delta)
		PDCState.TRACKING:
			handle_tracking(delta)
		PDCState.FIRING:
			handle_firing(delta)
		PDCState.BURST_FIRING:
			handle_burst_firing(delta)
		PDCState.RELOADING:
			handle_reloading(delta)

func print_debug_info():
	print("--- PDC DEBUG ---")
	print("State: ", PDCState.keys()[current_state])
	if current_target:
		var distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
		print("Target: ", current_target.target_id, " at ", distance_km, " km")
		print("Target confidence: ", current_target.confidence)
	else:
		print("Target: NONE")
	print("Barrel rotation: ", rad_to_deg(barrel.rotation), " degrees")
	print("Global rotation: ", rad_to_deg(global_rotation), " degrees")
	print("Shots fired: ", shots_fired)

func update_target_from_sensors():
	if not ship_sensor_system:
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Get the best threat target from sensors
	var best_threat = ship_sensor_system.get_best_threat_target_data()
	
	if best_threat:
		var distance_meters = global_position.distance_to(best_threat.predicted_position) * WorldSettings.meters_per_pixel
		var distance_km = distance_meters / 1000.0
		
		if distance_meters <= max_range_meters:
			if not current_target or current_target.target_id != best_threat.target_id:
				current_target = best_threat
				print("PDC acquired target: ", current_target.target_id, " at ", distance_km, " km")
				current_state = PDCState.TRACKING
			else:
				current_target = best_threat
		else:
			if current_target:
				print("PDC target out of range: ", distance_km, " km")
				current_target = null
				current_state = PDCState.SCANNING
	else:
		if current_target:
			current_target = null
			current_state = PDCState.SCANNING

func handle_scanning(_delta):
	barrel.rotation = rest_angle
	
	if current_target:
		current_state = PDCState.TRACKING

func handle_tracking(delta):
	if not current_target or not current_target.is_reliable():
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# FIXED: Calculate proper intercept point
	var intercept_point = calculate_intercept()
	if intercept_point == Vector2.ZERO:
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# FIXED: Calculate angle from PDC to intercept point (in world space)
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var world_angle = direction_to_intercept.angle()
	
	# FIXED: Convert world angle to local barrel angle
	var desired_barrel_angle = world_angle - global_rotation
	
	# Normalize the angle to [-PI, PI]
	while desired_barrel_angle > PI:
		desired_barrel_angle -= 2 * PI
	while desired_barrel_angle < -PI:
		desired_barrel_angle += 2 * PI
	
	# Rotate barrel towards target
	var angle_diff = angle_difference(barrel.rotation, desired_barrel_angle)
	var max_rotation = deg_to_rad(rotation_speed) * delta
	
	if abs(angle_diff) > max_rotation:
		barrel.rotation += sign(angle_diff) * max_rotation
	else:
		barrel.rotation = desired_barrel_angle
		
		# If aimed correctly, start firing
		if abs(angle_diff) < deg_to_rad(5.0):
			var distance_meters = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel
			
			if distance_meters > optimal_range_meters and burst_fire_mode:
				current_state = PDCState.BURST_FIRING
				burst_counter = 0
			else:
				current_state = PDCState.FIRING

func handle_firing(_delta):
	if not current_target or not current_target.is_reliable():
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Check if still aimed correctly
	var intercept_point = calculate_intercept()
	if intercept_point == Vector2.ZERO:
		current_state = PDCState.TRACKING
		return
	
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var world_angle = direction_to_intercept.angle()
	var desired_barrel_angle = world_angle - global_rotation
	var angle_diff = angle_difference(barrel.rotation, desired_barrel_angle)
	
	if abs(angle_diff) > deg_to_rad(10.0):
		current_state = PDCState.TRACKING
		return
	
	# Fire if ready
	if fire_timer >= (1.0 / fire_rate) and bullet_scene:
		fire_bullet()
		fire_timer = 0.0

func handle_burst_firing(_delta):
	if not current_target or not current_target.is_reliable():
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	if fire_timer >= (1.0 / fire_rate) and bullet_scene:
		if burst_counter < burst_size:
			fire_bullet_with_spread()
			burst_counter += 1
			fire_timer = 0.0
		else:
			current_state = PDCState.RELOADING
			burst_counter = 0

func handle_reloading(_delta):
	if fire_timer >= 0.5:  # 500ms reload time
		if current_target:
			var distance_meters = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel
			if distance_meters > optimal_range_meters and burst_fire_mode:
				current_state = PDCState.BURST_FIRING
			else:
				current_state = PDCState.FIRING
		else:
			current_state = PDCState.SCANNING

func calculate_intercept() -> Vector2:
	if not current_target:
		return Vector2.ZERO
	
	var target_pos = current_target.predicted_position
	var target_vel = current_target.velocity
	var distance = global_position.distance_to(target_pos)
	
	# FIXED: More reasonable bullet speed calculation
	var bullet_speed_pixels = muzzle_velocity_mps / WorldSettings.meters_per_pixel
	
	# Simple intercept calculation
	var time_to_intercept = distance / bullet_speed_pixels
	var lead_time = time_to_intercept + targeting_lead_time
	
	return target_pos + target_vel * lead_time

func fire_bullet():
	if not bullet_scene:
		print("Error: PDC bullet_scene is null!")
		return
	
	var bullet = bullet_scene.instantiate()
	if not bullet:
		print("Error: Failed to instantiate bullet!")
		return
	
	get_tree().root.add_child(bullet)
	
	# FIXED: Position bullet at correct global muzzle position
	bullet.global_position = muzzle_marker.global_position
	
	# FIXED: Calculate correct bullet direction in world space
	var intercept_point = calculate_intercept()
	var bullet_direction: Vector2
	
	if intercept_point != Vector2.ZERO:
		bullet_direction = (intercept_point - bullet.global_position).normalized()
	else:
		# Fallback: shoot in barrel direction
		bullet_direction = Vector2.RIGHT.rotated(barrel.global_rotation)
	
	# FIXED: Set reasonable bullet velocity
	if bullet.has_method("set_velocity"):
		var bullet_vel_pixels = bullet_direction * (muzzle_velocity_mps / WorldSettings.meters_per_pixel)
		bullet.set_velocity(bullet_vel_pixels)
		print("Bullet velocity set to: ", bullet_vel_pixels.length(), " pixels/second")
	
	if bullet.has_method("set_faction"):
		bullet.set_faction(pdc_faction)
	
	shots_fired += 1
	
	var distance_km = 0.0
	if current_target:
		distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
	
	print("PDC fired shot #", shots_fired, " at angle ", rad_to_deg(bullet_direction.angle()), "° (target at ", distance_km, " km)")

func fire_bullet_with_spread():
	if not bullet_scene:
		return
	
	var bullet = bullet_scene.instantiate()
	if not bullet:
		return
	
	get_tree().root.add_child(bullet)
	bullet.global_position = muzzle_marker.global_position
	
	var intercept_point = calculate_intercept()
	var base_direction: Vector2
	
	if intercept_point != Vector2.ZERO:
		base_direction = (intercept_point - bullet.global_position).normalized()
	else:
		base_direction = Vector2.RIGHT.rotated(barrel.global_rotation)
	
	# Add spread
	var spread_angle = deg_to_rad(randf_range(-burst_spread_degrees, burst_spread_degrees))
	var bullet_direction = base_direction.rotated(spread_angle)
	
	if bullet.has_method("set_velocity"):
		var bullet_vel_pixels = bullet_direction * (muzzle_velocity_mps / WorldSettings.meters_per_pixel)
		bullet.set_velocity(bullet_vel_pixels)
	
	if bullet.has_method("set_faction"):
		bullet.set_faction(pdc_faction)
	
	shots_fired += 1

func get_debug_info() -> String:
	var state_name = PDCState.keys()[current_state]
	var target_name: String
	var target_distance_km: float = 0.0
	
	if current_target:
		target_name = current_target.target_id
		target_distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
	else:
		target_name = "none"
	
	return "PDC [%s] Target: %s (%.1f km) | Shots: %d | Barrel: %.1f°" % [
		state_name, target_name, target_distance_km, shots_fired, rad_to_deg(barrel.rotation)
	]
