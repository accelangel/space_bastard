# Scripts/Entities/Weapons/PDCSystem.gd - FIXED VERSION
extends Node2D

# CRITICAL FIXES APPLIED:
# 1. Fixed unit conversions - properly handle meters vs pixels
# 2. Fixed engagement range logic - only fire when target is in range
# 3. Improved target lock stability - less thrashing
# 4. Better angle calculations and rotation handling

# PDC Hardware Configuration
@export var turret_rotation_speed: float = 90.0  # degrees/second
@export var max_rotation_speed_multiplier: float = 2.0
@export var bullet_velocity_mps: float = 800.0
@export var rounds_per_second: float = 18.0

# FIXED: Add engagement range checking
@export var engagement_range_meters: float = 28000.0  # 28 km
@export var engagement_range_min_meters: float = 5000.0  # 5 km minimum

# Firing state
var is_firing: bool = false
var fire_timer: float = 0.0
var current_rotation: float = 0.0
var target_rotation: float = 0.0
var emergency_slew: bool = false

# PDC Identity
var pdc_id: String = ""
var mount_position: Vector2
var current_status: String = "IDLE"  # IDLE, TRACKING, FIRING

# Target tracking
var current_target: Node2D = null
var current_target_id: String = ""
var last_target_position: Vector2 = Vector2.ZERO
var target_distance_meters: float = 0.0

# References
var parent_ship: Node2D
var fire_control_manager: Node
var sprite: Sprite2D
var muzzle_point: Marker2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics
var rounds_fired: int = 0

# Debug
var debug_enabled: bool = false
var debug_timer: float = 0.0
var last_debug_status: String = ""

func _ready():
	parent_ship = get_parent()
	sprite = get_node_or_null("Sprite2D")
	
	if sprite:
		muzzle_point = sprite.get_node_or_null("MuzzlePoint")
	
	mount_position = position
	pdc_id = "PDC_%d_%d" % [int(position.x), int(position.y)]
	
	print("PDC initialized: ", pdc_id, " at mount position: ", mount_position)

func _physics_process(delta):
	update_target_tracking()
	update_turret_rotation(delta)
	handle_firing(delta)
	
	# Debug output
	if debug_enabled:
		debug_timer += delta
		if debug_timer >= 1.0:
			debug_timer = 0.0
			print_debug_status()

func update_target_tracking():
	# FIXED: Properly track target and calculate distance in meters
	if current_target and is_instance_valid(current_target):
		last_target_position = current_target.global_position
		
		# FIXED: Convert distance to meters properly
		var distance_pixels = global_position.distance_to(last_target_position)
		target_distance_meters = distance_pixels * WorldSettings.meters_per_pixel
	else:
		target_distance_meters = 0.0
		current_target = null
		current_target_id = ""

func update_turret_rotation(delta):
	if sprite:
		var angle_diff = angle_difference(current_rotation, target_rotation)
		var rotation_speed = deg_to_rad(turret_rotation_speed)
		
		if emergency_slew:
			rotation_speed *= max_rotation_speed_multiplier
		
		var rotation_step = rotation_speed * delta
		
		if abs(angle_diff) > rotation_step:
			current_rotation += sign(angle_diff) * rotation_step
		else:
			current_rotation = target_rotation
		
		# Apply rotation relative to ship
		sprite.rotation = current_rotation - parent_ship.rotation

func handle_firing(delta):
	# FIXED: Only fire if target is in engagement range
	var can_fire = (
		current_target != null and 
		is_instance_valid(current_target) and
		target_distance_meters > 0.0 and
		target_distance_meters <= engagement_range_meters and
		target_distance_meters >= engagement_range_min_meters and
		is_aimed()
	)
	
	if can_fire and is_firing:
		fire_timer += delta
		var fire_interval = 1.0 / rounds_per_second
		
		if fire_timer >= fire_interval:
			fire_bullet()
			fire_timer = 0.0
	elif not can_fire and is_firing:
		# Stop firing if conditions are no longer met
		stop_firing()

func set_target(target_id: String, target_angle: float, is_emergency: bool = false):
	current_target_id = target_id
	target_rotation = target_angle
	emergency_slew = is_emergency
	
	# FIXED: Find the actual target node for distance checking
	if fire_control_manager and fire_control_manager.tracked_targets.has(target_id):
		var target_data = fire_control_manager.tracked_targets[target_id]
		current_target = target_data.node_ref
	
	current_status = "TRACKING"

func start_firing():
	# FIXED: Only start firing if target is in engagement range
	if (current_status == "TRACKING" and 
		is_aimed() and 
		target_distance_meters > 0.0 and
		target_distance_meters <= engagement_range_meters and
		target_distance_meters >= engagement_range_min_meters):
		
		is_firing = true
		current_status = "FIRING"
		fire_timer = 0.0

func stop_firing():
	is_firing = false
	current_status = "IDLE"
	current_target = null
	current_target_id = ""

func is_aimed() -> bool:
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	return angle_diff < deg_to_rad(5.0)

func get_tracking_error() -> float:
	return abs(angle_difference(current_rotation, target_rotation))

func fire_bullet():
	if not bullet_scene:
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# Position at muzzle
	bullet.global_position = get_muzzle_world_position()
	
	# Calculate world firing angle
	var world_angle = current_rotation + parent_ship.rotation
	var fire_direction = Vector2.from_angle(world_angle)
	
	# Add ship velocity to bullet
	var ship_velocity = get_ship_velocity()
	var bullet_velocity = fire_direction * bullet_velocity_mps + ship_velocity
	var bullet_velocity_pixels = bullet_velocity / WorldSettings.meters_per_pixel
	
	if bullet.has_method("set_velocity"):
		bullet.set_velocity(bullet_velocity_pixels)
	
	# Set faction
	if parent_ship and "faction" in parent_ship:
		if bullet.has_method("set_faction"):
			bullet.set_faction(parent_ship.faction)
	
	rounds_fired += 1
	
	# Debug firing
	if debug_enabled and rounds_fired % 36 == 0:  # Every 2 seconds
		print("PDC %s: Fired at target %.1f km away" % [
			pdc_id, 
			target_distance_meters / 1000.0
		])

func print_debug_status():
	var new_status = ""
	if current_target_id != "":
		new_status = "%s -> %s (%.1f km, %.1f° error)" % [
			current_status,
			current_target_id.substr(0, 15),
			target_distance_meters / 1000.0,
			rad_to_deg(get_tracking_error())
		]
	else:
		new_status = current_status
	
	if new_status != last_debug_status:
		print("PDC %s: %s" % [pdc_id, new_status])
		last_debug_status = new_status

func get_muzzle_world_position() -> Vector2:
	if muzzle_point:
		return muzzle_point.global_position
	return global_position

func get_ship_velocity() -> Vector2:
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		return parent_ship.get_velocity_mps()
	return Vector2.ZERO

func angle_difference(from: float, to: float) -> float:
	var diff = fmod(to - from, TAU)
	if diff > PI:
		diff -= TAU
	elif diff < -PI:
		diff += TAU
	return diff

# Status reporting for Fire Control Manager
func get_status() -> Dictionary:
	return {
		"pdc_id": pdc_id,
		"status": current_status,
		"current_rotation": current_rotation,
		"target_rotation": target_rotation,
		"tracking_error": get_tracking_error(),
		"is_aimed": is_aimed(),
		"rounds_fired": rounds_fired,
		"current_target": current_target_id,
		"mount_position": mount_position
	}

# Get capabilities for Fire Control Manager
func get_capabilities() -> Dictionary:
	return {
		"rotation_speed": turret_rotation_speed,
		"max_rotation_speed": turret_rotation_speed * max_rotation_speed_multiplier,
		"bullet_velocity": bullet_velocity_mps,
		"fire_rate": rounds_per_second
	}

# Set Fire Control Manager reference
func set_fire_control_manager(manager: Node):
	fire_control_manager = manager

# Emergency stop
func emergency_stop():
	stop_firing()
	emergency_slew = false
	current_status = "IDLE"
