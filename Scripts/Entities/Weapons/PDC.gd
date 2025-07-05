# Scripts/Weapons/PDC.gd - LONG RANGE DEFENSE SYSTEM
extends Node2D
class_name PDC

# DEFENSIVE SPECIFICATIONS - Long range interception
@export var max_range_meters: float = 50000.0    # 50km engagement range
@export var optimal_range_meters: float = 25000.0 # 25km optimal engagement
@export var rotation_speed: float = 360.0        # Degrees per second - very fast
@export var fire_rate: float = 30.0              # 30 rounds per second - high volume
@export var muzzle_velocity_mps: float = 2000.0  # 2km/s bullet velocity
@export var targeting_lead_time: float = 2.0     # Lead targets by 2 seconds

# Defensive fire patterns
@export var burst_fire_mode: bool = true         # Fire in bursts to create barriers
@export var burst_size: int = 10                 # Bullets per burst
@export var burst_spread_degrees: float = 5.0    # Spread pattern for area denial

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
var target_update_interval: float = 0.1  # Fast target updates for defense
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
var scanning_angle: float = 0.0  # For scanning rotation
var rest_angle: float = 0.0      # Default forward-facing angle

func _ready():
	print("=== LONG-RANGE PDC STARTING UP ===")
	
	# Get parent ship reference
	parent_ship = get_parent()
	if parent_ship:
		print("PDC parent ship: ", parent_ship.name)
		
		# Find the ship's sensor system
		ship_sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if ship_sensor_system:
			print("PDC found military radar system: ", ship_sensor_system.name)
		else:
			print("ERROR: PDC could not find ship sensor system!")
	else:
		print("ERROR: PDC has no parent ship!")
	
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
	
	print("PDC initialized with faction: ", pdc_faction)
	print("PDC ENGAGEMENT RANGE: ", max_range_meters / 1000.0, " km")
	print("PDC OPTIMAL RANGE: ", optimal_range_meters / 1000.0, " km")
	
	# If bullet_scene is not assigned, try to load it
	if not bullet_scene:
		bullet_scene = preload("res://Scenes/PDCBullet.tscn")
	if bullet_scene:
		print("PDC loaded bullet scene: true")
	else:
		print("PDC loaded bullet scene: false")
	
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
	
	# Set initial barrel position to face forward (up)
	rest_angle = deg_to_rad(-90)  # -90 degrees = pointing up
	barrel.rotation = rest_angle
	scanning_angle = rest_angle
	
	print("PDC setup complete, engagement ready")
	print("=== LONG-RANGE PDC READY ===")

func _physics_process(delta):
	debug_frame_count += 1
	target_update_timer += delta
	fire_timer += delta
	
	# Debug output every 3 seconds
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_time > 3.0:
		print_debug_info()
		last_debug_time = current_time
	
	# Update target search periodically using SensorSystem
	if target_update_timer >= target_update_interval:
		update_target_from_military_radar()
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
		PDCState.OFFLINE:
			handle_offline(delta)

func print_debug_info():
	print("--- LONG-RANGE PDC DEBUG ---")
	print("State: ", PDCState.keys()[current_state])
	if current_target:
		var distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
		print("Current target: ", current_target.target_id)
		print("Target distance: ", distance_km, " km")
		print("Target confidence: ", current_target.confidence)
	else:
		print("Current target: NONE")
	print("Faction: ", pdc_faction)
	print("Global position: ", global_position)
	print("Shots fired: ", shots_fired)
	
	# Check sensor system status
	if ship_sensor_system:
		print("Military radar active: true")
		var threat_data = ship_sensor_system.get_target_data_for_threats()
		print("Threats detected: ", threat_data.size())
	else:
		print("Military radar active: false")
	
	print("--- END PDC DEBUG ---")

# Use ship's military radar to find threats at extreme range
func update_target_from_military_radar():
	print("PDC scanning for long-range threats...")
	
	if not ship_sensor_system:
		print("ERROR: No military radar available!")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Get the best threat target from military radar
	var best_threat = ship_sensor_system.get_best_threat_target_data()
	
	if best_threat:
		# Check if this target is within our engagement envelope
		var distance_meters = global_position.distance_to(best_threat.predicted_position) * WorldSettings.meters_per_pixel
		var distance_km = distance_meters / 1000.0
		
		if distance_meters <= max_range_meters:
			# Check if this is a new target or an update to current target
			if not current_target or current_target.target_id != best_threat.target_id:
				current_target = best_threat
				print("PDC acquired long-range threat: ", current_target.target_id, " at ", distance_km, " km")
				current_state = PDCState.TRACKING
			else:
				# Update current target data
				current_target = best_threat
				print("PDC tracking: ", current_target.target_id, " at ", distance_km, " km")
		else:
			print("PDC threat out of range: ", distance_km, " km (max: ", max_range_meters / 1000.0, " km)")
			if current_target:
				current_target = null
				current_state = PDCState.SCANNING
	else:
		print("PDC no threats detected by military radar")
		if current_target:
			current_target = null
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
	
	# Calculate long-range intercept point with extended lead time
	var intercept_point = calculate_long_range_intercept()
	if intercept_point == Vector2.ZERO:
		print("PDC can't calculate long-range intercept, returning to scanning")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	var distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
	print("PDC tracking at ", distance_km, " km, intercept: ", intercept_point)
	
	# Calculate desired barrel angle
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var desired_angle = direction_to_intercept.angle() - global_rotation
	
	# Rotate barrel towards intercept point (fast rotation for defense)
	var angle_diff = angle_difference(barrel.rotation, desired_angle)
	var max_rotation = deg_to_rad(rotation_speed) * delta
	
	print("PDC angle diff: ", rad_to_deg(angle_diff), " degrees")
	
	if abs(angle_diff) > max_rotation:
		barrel.rotation += sign(angle_diff) * max_rotation
	else:
		barrel.rotation = desired_angle
		
		# If we're aimed correctly, determine firing mode based on range
		if abs(angle_diff) < deg_to_rad(10.0):
			var distance_meters = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel
			
			if distance_meters > optimal_range_meters and burst_fire_mode:
				print("PDC switching to BURST FIRING (long range)")
				current_state = PDCState.BURST_FIRING
				burst_counter = 0
			else:
				print("PDC switching to FIRING (standard)")
				current_state = PDCState.FIRING

func handle_firing(_delta):
	if not current_target or not current_target.is_reliable():
		print("PDC lost target during firing, returning to scanning")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Check if we're still aimed correctly
	var intercept_point = calculate_long_range_intercept()
	if intercept_point == Vector2.ZERO:
		print("PDC lost intercept during firing, returning to tracking")
		current_state = PDCState.TRACKING
		return
	
	var direction_to_intercept = (intercept_point - global_position).normalized()
	var desired_angle = direction_to_intercept.angle() - global_rotation
	var angle_diff = angle_difference(barrel.rotation, desired_angle)
	
	if abs(angle_diff) > deg_to_rad(15.0):
		print("PDC lost aim during firing, returning to tracking")
		current_state = PDCState.TRACKING
		return
	
	# Fire if ready and we have a bullet scene
	if fire_timer >= (1.0 / fire_rate) and bullet_scene:
		print("PDC FIRING!")
		fire_bullet()
		fire_timer = 0.0

func handle_burst_firing(_delta):
	if not current_target or not current_target.is_reliable():
		print("PDC lost target during burst firing, returning to scanning")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Fire bursts with spread for area denial
	if fire_timer >= (1.0 / fire_rate) and bullet_scene:
		if burst_counter < burst_size:
			print("PDC BURST FIRE! (", burst_counter + 1, "/", burst_size, ")")
			fire_bullet_with_spread()
			burst_counter += 1
			fire_timer = 0.0
		else:
			# Burst complete, brief pause then new burst
			print("PDC burst complete, reloading...")
			current_state = PDCState.RELOADING
			burst_counter = 0

func handle_reloading(_delta):
	# Brief pause between bursts
	if fire_timer >= 0.3:  # 300ms reload time
		if current_target:
			var distance_meters = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel
			if distance_meters > optimal_range_meters and burst_fire_mode:
				current_state = PDCState.BURST_FIRING
			else:
				current_state = PDCState.FIRING
		else:
			current_state = PDCState.SCANNING

func handle_offline(_delta):
	# PDC is offline - do nothing
	pass

func calculate_long_range_intercept() -> Vector2:
	if not current_target:
		return Vector2.ZERO
	
	var target_pos = current_target.predicted_position
	var target_vel = current_target.velocity
	var distance = global_position.distance_to(target_pos)
	
	# For long-range intercepts, calculate proper ballistic solution
	var bullet_speed = muzzle_velocity_mps / WorldSettings.meters_per_pixel
	
	# Time for bullet to reach target (accounting for target movement)
	var time_to_intercept = distance / bullet_speed
	
	# Extended lead time for long-range shots
	var total_lead_time = time_to_intercept + targeting_lead_time
	
	# Predict where target will be
	var intercept_point = target_pos + target_vel * total_lead_time
	
	# For very long range, add some spread prediction
	var distance_km = distance * WorldSettings.meters_per_pixel / 1000.0
	if distance_km > 30.0:  # >30km, add uncertainty
		var spread_factor = (distance_km - 30.0) / 20.0  # Increases with range
		var spread_offset = Vector2(
			randf_range(-50.0, 50.0) * spread_factor,
			randf_range(-50.0, 50.0) * spread_factor
		)
		intercept_point += spread_offset
	
	return intercept_point

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
	var intercept_point = calculate_long_range_intercept()
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
	
	shots_fired += 1
	
	var distance_km = 0.0
	if current_target:
		distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
		print("PDC (faction %d) fired shot #%d at %s (%.1f km)" % [pdc_faction, shots_fired, current_target.target_id, distance_km])
	else:
		print("PDC (faction %d) fired shot #%d (no target)" % [pdc_faction, shots_fired])

func fire_bullet_with_spread():
	if not bullet_scene:
		print("Error: PDC bullet_scene is null! Cannot fire spread.")
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
	
	# Calculate bullet direction with spread
	var intercept_point = calculate_long_range_intercept()
	var base_direction = Vector2.RIGHT.rotated(barrel.global_rotation)
	
	if intercept_point != Vector2.ZERO:
		base_direction = (intercept_point - muzzle_global_pos).normalized()
	
	# Add spread for area denial
	var spread_angle = deg_to_rad(randf_range(-burst_spread_degrees, burst_spread_degrees))
	var bullet_direction = base_direction.rotated(spread_angle)
	
	# Set bullet velocity
	if bullet.has_method("set_velocity"):
		var bullet_vel_pixels = bullet_direction * (muzzle_velocity_mps / WorldSettings.meters_per_pixel)
		bullet.set_velocity(bullet_vel_pixels)
	
	# Set bullet faction to match PDC
	if bullet.has_method("set_faction"):
		bullet.set_faction(pdc_faction)
	
	shots_fired += 1
	
	var distance_km = 0.0
	if current_target:
		distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
		print("PDC (faction %d) burst shot #%d at %s (%.1f km, spread: %.1f°)" % [pdc_faction, shots_fired, current_target.target_id, distance_km, rad_to_deg(spread_angle)])

func set_offline(offline: bool):
	if offline:
		current_state = PDCState.OFFLINE
		current_target = null
	else:
		current_state = PDCState.SCANNING

func get_debug_info() -> String:
	var state_name = PDCState.keys()[current_state]
	var target_name: String
	var target_distance_km: float = 0.0
	
	if current_target:
		target_name = current_target.target_id
		target_distance_km = global_position.distance_to(current_target.predicted_position) * WorldSettings.meters_per_pixel / 1000.0
	else:
		target_name = "none"
	
	return "LONG-RANGE PDC [%s] Faction: %d | Target: %s (%.1f km) | Shots: %d | Angle: %.1f°" % [
		state_name, pdc_faction, target_name, target_distance_km, shots_fired, rad_to_deg(barrel.rotation)
	]
