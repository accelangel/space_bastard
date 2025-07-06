# Scripts/Entities/Weapons/PDCSystem.gd - COMPLETE FIRE CONTROL REWRITE
extends Node2D

# This PDC is now a "dumb actuator" - it receives commands from the ship's Fire Control Manager
# It focuses purely on mechanical operation: rotation, firing, and reporting status

# PDC Hardware Configuration
@export var turret_rotation_speed: float = 90.0  # degrees/second
@export var max_rotation_speed_multiplier: float = 2.0  # Emergency slew rate multiplier
@export var bullet_velocity_mps: float = 800.0
@export var rounds_per_second: float = 18.0  # Constant fire rate as per architecture

# Firing state
var is_firing: bool = false
var fire_timer: float = 0.0
var current_rotation: float = 0.0
var target_rotation: float = 0.0
var emergency_slew: bool = false

# PDC Identity
var pdc_id: String = ""
var mount_position: Vector2  # Position relative to ship center
var current_status: String = "IDLE"  # IDLE, TRACKING, FIRING

# References
var parent_ship: Node2D
var fire_control_manager: Node  # Will be set by the manager
var sprite: Sprite2D
var muzzle_point: Marker2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics for reporting
var rounds_fired: int = 0
var current_target_id: String = ""

func _ready():
	parent_ship = get_parent()
	sprite = get_node_or_null("Sprite2D")
	
	if sprite:
		muzzle_point = sprite.get_node_or_null("MuzzlePoint")
	
	# Record mount position relative to ship
	mount_position = position
	
	# Generate unique ID based on position
	pdc_id = "PDC_%d_%d" % [int(position.x), int(position.y)]
	
	print("PDC initialized: ", pdc_id, " at mount position: ", mount_position)

func _physics_process(delta):
	# Update turret rotation
	update_turret_rotation(delta)
	
	# Handle firing if commanded
	if is_firing:
		fire_timer += delta
		var fire_interval = 1.0 / rounds_per_second
		
		if fire_timer >= fire_interval:
			fire_bullet()
			fire_timer = 0.0

# Called by Fire Control Manager to assign a new target
func set_target(target_id: String, target_angle: float, is_emergency: bool = false):
	current_target_id = target_id
	target_rotation = target_angle
	emergency_slew = is_emergency
	current_status = "TRACKING"

# Called by Fire Control Manager to start firing
func start_firing():
	if current_status == "TRACKING" and is_aimed():
		is_firing = true
		current_status = "FIRING"
		fire_timer = 0.0

# Called by Fire Control Manager to stop firing
func stop_firing():
	is_firing = false
	current_status = "IDLE"
	current_target_id = ""

# Check if turret is aimed at target
func is_aimed() -> bool:
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	return angle_diff < deg_to_rad(5.0)  # Within 5 degrees

# Get current tracking error in radians
func get_tracking_error() -> float:
	return abs(angle_difference(current_rotation, target_rotation))

# Update turret rotation
func update_turret_rotation(delta):
	if sprite:
		var angle_diff = angle_difference(current_rotation, target_rotation)
		var rotation_speed = deg_to_rad(turret_rotation_speed)
		
		# Apply emergency slew rate if needed
		if emergency_slew:
			rotation_speed *= max_rotation_speed_multiplier
		
		var rotation_step = rotation_speed * delta
		
		if abs(angle_diff) > rotation_step:
			current_rotation += sign(angle_diff) * rotation_step
		else:
			current_rotation = target_rotation
			
			# Report ready to fire if tracking
			if current_status == "TRACKING":
				report_ready_to_fire()
		
		# Apply rotation relative to ship
		sprite.rotation = current_rotation - parent_ship.rotation

# Fire a single bullet
func fire_bullet():
	if not bullet_scene:
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# Position at muzzle
	bullet.global_position = get_muzzle_world_position()
	
	# Fire in current direction
	var fire_direction = Vector2.from_angle(current_rotation)
	
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
