# Scripts/Entities/Weapons/PDCSystem.gd - FIXED VERSION
extends Node2D

# PDC Hardware Configuration
@export var turret_rotation_speed: float = 90.0  # degrees/second
@export var max_rotation_speed_multiplier: float = 2.0  # Emergency slew rate multiplier
@export var bullet_velocity_mps: float = 800.0
@export var rounds_per_second: float = 18.0
@export var max_effective_range_meters: float = 3000.0  # Don't engage beyond this range
@export var min_engagement_range_meters: float = 100.0   # Don't engage closer than this

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

# References
var parent_ship: Node2D
var fire_control_manager: Node
var sprite: Sprite2D
var muzzle_point: Marker2D

# Current target info
var current_target_id: String = ""
var current_target_position: Vector2
var current_target_range: float = 0.0

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics
var rounds_fired: int = 0

# DEBUG
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
	update_turret_rotation(delta)
	
	# Only fire if we're supposed to AND target is in range
	if is_firing and is_target_in_range():
		fire_timer += delta
		var fire_interval = 1.0 / rounds_per_second
		
		if fire_timer >= fire_interval:
			fire_bullet()
			fire_timer = 0.0
	
	# DEBUG: Less frequent status updates
	debug_timer += delta
	if debug_timer >= 2.0:  # Every 2 seconds
		debug_timer = 0.0
		var new_status = "%s rot:%.1f°->%.1f° (%.1f°) range:%.0fm" % [
			current_status, 
			rad_to_deg(current_rotation),
			rad_to_deg(target_rotation),
			rad_to_deg(get_tracking_error()),
			current_target_range
		]
		if new_status != last_debug_status:
			print("PDC %s: %s" % [pdc_id, new_status])
			last_debug_status = new_status

# Called by Fire Control Manager to assign a new target
func set_target(target_id: String, target_position: Vector2, target_angle: float, is_emergency: bool = false):
	current_target_id = target_id
	current_target_position = target_position
	target_rotation = target_angle
	emergency_slew = is_emergency
	current_status = "TRACKING"
	
	# Calculate range to target
	var distance_pixels = global_position.distance_to(target_position)
	current_target_range = distance_pixels * WorldSettings.meters_per_pixel
	
	# DEBUG: Log target assignment with range check
	var angle_deg = rad_to_deg(target_angle)
	var current_deg = rad_to_deg(current_rotation)
	var in_range = is_target_in_range()
	
	print("PDC %s: New target %s at %.1f° (current: %.1f°, emergency: %s, range: %.0fm, in_range: %s)" % [
		pdc_id, target_id.substr(0, 15), angle_deg, current_deg, str(is_emergency), current_target_range, str(in_range)
	])

# Check if current target is within engagement range
func is_target_in_range() -> bool:
	if current_target_id == "":
		return false
	
	return current_target_range >= min_engagement_range_meters and current_target_range <= max_effective_range_meters

# Called by Fire Control Manager to start firing
func start_firing():
	# Only start firing if we're tracking, aimed, and target is in range
	if current_status == "TRACKING" and is_aimed() and is_target_in_range():
		is_firing = true
		current_status = "FIRING"
		fire_timer = 0.0
		print("PDC %s: Starting to fire at target %s (range: %.0fm)" % [
			pdc_id, current_target_id.substr(0, 15), current_target_range
		])
	else:
		# Log why we're not firing
		var reason = ""
		if current_status != "TRACKING":
			reason = "not tracking"
		elif not is_aimed():
			reason = "not aimed"
		elif not is_target_in_range():
			reason = "out of range"
		
		print("PDC %s: Cannot fire - %s" % [pdc_id, reason])

# Called by Fire Control Manager to stop firing
func stop_firing():
	is_firing = false
	current_status = "IDLE"
	current_target_id = ""
	current_target_position = Vector2.ZERO
	current_target_range = 0.0

# Check if turret is aimed at target (tighter tolerance)
func is_aimed() -> bool:
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	return angle_diff < deg_to_rad(2.0)  # Within 2 degrees (tighter than before)

# Get current tracking error in radians
func get_tracking_error() -> float:
	return abs(angle_difference(current_rotation, target_rotation))

# Update turret rotation
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
			
			# Report ready to fire if tracking and in range
			if current_status == "TRACKING" and is_target_in_range():
				report_ready_to_fire()
		
		# Apply rotation relative to ship
		sprite.rotation = current_rotation

# Fire a single bullet
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
	
	# DEBUG: Log firing less frequently
	if rounds_fired % 36 == 0:  # Every 2 seconds at 18 RPS
		print("PDC %s firing - ship: %.1f°, relative: %.1f°, world: %.1f°, range: %.0fm" % [
			pdc_id, 
			rad_to_deg(parent_ship.rotation),
			rad_to_deg(current_rotation),
			rad_to_deg(world_angle),
			current_target_range
		])

# Report to Fire Control Manager that we're ready to fire
func report_ready_to_fire():
	if fire_control_manager and fire_control_manager.has_method("pdc_ready_to_fire"):
		fire_control_manager.pdc_ready_to_fire(pdc_id)

# Get world position of muzzle
func get_muzzle_world_position() -> Vector2:
	if muzzle_point:
		return muzzle_point.global_position
	return global_position

# Get ship velocity for bullet inheritance
func get_ship_velocity() -> Vector2:
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		return parent_ship.get_velocity_mps()
	return Vector2.ZERO

# Utility function for angle math
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
		"mount_position": mount_position,
		"target_range": current_target_range,
		"in_range": is_target_in_range()
	}

# Get capabilities for Fire Control Manager
func get_capabilities() -> Dictionary:
	return {
		"rotation_speed": turret_rotation_speed,
		"max_rotation_speed": turret_rotation_speed * max_rotation_speed_multiplier,
		"bullet_velocity": bullet_velocity_mps,
		"fire_rate": rounds_per_second,
		"max_range": max_effective_range_meters,
		"min_range": min_engagement_range_meters
	}

# Set Fire Control Manager reference
func set_fire_control_manager(manager: Node):
	fire_control_manager = manager

# Emergency stop
func emergency_stop():
	stop_firing()
	emergency_slew = false
	current_status = "IDLE"
	current_target_id = ""
	current_target_position = Vector2.ZERO
	current_target_range = 0.0
