# Scripts/Weapons/PDC.gd - UPDATED to use SensorSystem
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

# Ship's sensor system reference
var ship_sensor_system: SensorSystem = null

# Performance settings
var target_update_interval: float = 0.2  # How often to check for new targets
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
		
		# Find the ship's sensor system
		ship_sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if ship_sensor_system:
			print("PDC found ship sensor system: ", ship_sensor_system.name)
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
	
	# Update target search periodically using SensorSystem
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
		PDCState.RELOADING:
			handle_reloading(delta)
		PDCState.OFFLINE:
			handle_offline(delta)

func print_debug_info():
	print("--- PDC DEBUG ---")
	print("State: ", PDCState.keys()[current_state])
	if current_target:
		print("Current target: ", current_target.target_id)
		print("Target confidence: ", current_target.confidence)
		print("Target data age: ", current_target.data_age)
	else:
		print("Current target: NONE")
	print("Faction: ", pdc_faction)
	print("Global position: ", global_position)
	
	# Check sensor system status
	if ship_sensor_system:
		print("Sensor system active: true")
		var threat_data = ship_sensor_system.get_target_data_for_threats()
		print("Threats detected by sensors: ", threat_data.size())
		for threat in threat_data:
			print("  Threat: ", threat.target_id, " confidence: ", threat.confidence)
	else:
		print("Sensor system active: false")
	
	print("--- END DEBUG ---")

# NEW: Use ship's sensor system to find targets
func update_target_from_sensors():
	print("PDC checking sensor system for threats...")
	
	if not ship_sensor_system:
		print("ERROR: No sensor system available!")
		current_target = null
		current_state = PDCState.SCANNING
		return
	
	# Get the best threat target from sensors
	var best_threat = ship_sensor_system.get_best_threat_target_data()
	
	if best_threat:
		# Check if this target is within our engagement range
		var distance_meters = global_position.distance_to(best_threat.predicted_position) * WorldSettings.meters_per_pixel
		
		if distance_meters <= max_range_meters:
			# Check if this is a new target or an update to current target
			if not current_target or current_target.target_id != best_threat.target_id:
				current_target = best_threat
				print("PDC acquired new threat: ", current_target.target_id, " at range ", distance_meters, "m")
				current_state = PDCState.TRACKING
			else:
				# Update current target data
				current_target = best_threat
				print("PDC updated target data for: ", current_target.target_id)
		else:
			print("PDC best threat out of range: ", distance_meters, "m (max: ", max_range_meters, "m)")
			if current_target:
				current_target = null
				current_state = PDCState.SCANNING
	else:
		print("PDC no threats detected by sensors")
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
		print("PDC (faction %d) fired at threat: %s" % [pdc_faction, current_target.target_id])
	else:
		print("PDC (faction %d) fired at threat: none" % [pdc_faction])

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
