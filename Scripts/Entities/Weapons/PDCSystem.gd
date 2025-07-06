# Scripts/Entities/Weapons/PDCSystem.gd - FIRING FIXED VERSION
extends Node2D

# CRITICAL FIXES APPLIED:
# 1. Fixed firing authorization - PDCs now actually fire when conditions are met
# 2. Simplified range checking - removed conflicting logic
# 3. Better target tracking and engagement states
# 4. Fixed the "never fires" bug by proper state management

# PDC Hardware Configuration
@export var turret_rotation_speed: float = 90.0  # degrees/second
@export var max_rotation_speed_multiplier: float = 2.0
@export var bullet_velocity_mps: float = 800.0
@export var rounds_per_second: float = 18.0

# SIMPLIFIED: Let FCM handle range checking, PDC just fires when told
@export var max_tracking_error: float = 5.0  # degrees - how accurate we need to be to fire

# Firing state
var is_firing: bool = false
var fire_timer: float = 0.0
var current_rotation: float = 0.0
var target_rotation: float = 0.0
var emergency_slew: bool = false

# PDC Identity
var pdc_id: String = ""
var mount_position: Vector2
var current_status: String = "IDLE"  # IDLE, TRACKING, FIRING, READY

# Target tracking
var current_target_id: String = ""
var target_distance_meters: float = 0.0
var fire_authorized: bool = false  # NEW: FCM must authorize firing

# References
var parent_ship: Node2D
var fire_control_manager: Node
var sprite: Sprite2D
var muzzle_point: Marker2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics
var rounds_fired: int = 0
var last_fire_time: float = 0.0

# Debug
var debug_enabled: bool = true
var debug_timer: float = 0.0

# Add this to _ready() to check sprite setup
func _ready():
	parent_ship = get_parent()
	sprite = get_node_or_null("Sprite2D")
	
	if sprite:
		muzzle_point = sprite.get_node_or_null("MuzzlePoint")
		
		# DEBUG: Check sprite default orientation
		print("PDC %s sprite setup:" % pdc_id)
		print("  Sprite default rotation: %.1f°" % rad_to_deg(sprite.rotation))
		print("  Sprite texture: %s" % sprite.texture.resource_path if sprite.texture else "None")
		
		# Test: Is the sprite image oriented correctly?
		# In Godot, 0° rotation should point right (+X axis)
		# But your PDC sprites might be drawn pointing up or down
		
	mount_position = position
	pdc_id = "PDC_%d_%d" % [int(position.x), int(position.y)]
	
	print("PDC initialized: ", pdc_id, " at mount position: ", mount_position)
	
	# Run sprite orientation check after a delay
	call_deferred("debug_sprite_orientation")

func _physics_process(delta):
	update_turret_rotation(delta)
	handle_firing(delta)
	
	# Debug output
	if debug_enabled:
		debug_timer += delta
		if debug_timer >= 2.0:
			debug_timer = 0.0
			if current_status != "IDLE":
				print("PDC %s: %s | Target: %s | Fire Auth: %s | Aimed: %s" % [
					pdc_id.substr(4, 8), current_status, current_target_id.substr(8, 7), 
					fire_authorized, is_aimed()
				])
				
# In PDCSystem.gd - update_turret_rotation() - KEEP AS IS
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
		
		# Apply rotation relative to ship - KEEP THIS
		sprite.rotation = current_rotation - parent_ship.rotation
		
func handle_firing(delta):
	# SIMPLIFIED FIRING LOGIC:
	# 1. If we have a target and are authorized to fire and aimed -> FIRE
	# 2. If we don't have authorization or target -> STOP
	
	var should_fire = (
		current_target_id != "" and 
		fire_authorized and 
		is_aimed()
	)
	
	if should_fire:
		if not is_firing:
			start_firing()
		
		# Handle continuous firing
		if is_firing:
			fire_timer += delta
			var fire_interval = 1.0 / rounds_per_second
			
			if fire_timer >= fire_interval:
				fire_bullet()
				fire_timer = 0.0
	else:
		if is_firing:
			stop_firing()

# FIXED: Simplified target assignment
func set_target(target_id: String, target_angle: float, is_emergency: bool = false):
	current_target_id = target_id
	target_rotation = target_angle
	emergency_slew = is_emergency
	fire_authorized = false  # Reset authorization, FCM will set it
	
	current_status = "TRACKING"
	
	if debug_enabled:
		print("PDC %s: Tracking target %s at angle %.1f°" % [
			pdc_id.substr(4, 8), target_id.substr(8, 7), rad_to_deg(target_angle)
		])

# NEW: FCM calls this to authorize firing
func authorize_firing():
	if current_target_id != "" and is_aimed():
		fire_authorized = true
		current_status = "READY"
		
		if debug_enabled:
			print("PDC %s: AUTHORIZED to fire on %s" % [
				pdc_id.substr(4, 8), current_target_id.substr(8, 7)
			])

# FIXED: Proper firing start
func start_firing():
	if not fire_authorized:
		if debug_enabled:
			print("PDC %s: Cannot fire - not authorized" % pdc_id.substr(4, 8))
		return
	
	if not is_aimed():
		if debug_enabled:
			print("PDC %s: Cannot fire - not aimed" % pdc_id.substr(4, 8))
		return
	
	is_firing = true
	current_status = "FIRING"
	fire_timer = 0.0
	last_fire_time = Time.get_ticks_msec() / 1000.0
	
	if debug_enabled:
		print("PDC %s: FIRING STARTED on target %s" % [
			pdc_id.substr(4, 8), current_target_id.substr(8, 7)
		])

func stop_firing():
	is_firing = false
	fire_authorized = false
	current_status = "IDLE"
	current_target_id = ""
	
	if debug_enabled and rounds_fired > 0:
		print("PDC %s: FIRING STOPPED (fired %d rounds)" % [
			pdc_id.substr(4, 8), rounds_fired
		])

func is_aimed() -> bool:
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	return angle_diff < deg_to_rad(max_tracking_error)

func get_tracking_error() -> float:
	return abs(angle_difference(current_rotation, target_rotation))

# Add this to fire_bullet() to see what's happening
func fire_bullet():
	if not bullet_scene:
		print("PDC %s: No bullet scene loaded!" % pdc_id)
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# Position at muzzle
	bullet.global_position = get_muzzle_world_position()
	
	# CURRENT METHOD: Use world angle directly
	var world_angle = current_rotation + PI # if this line is set to: var world_angle = current_rotation then the bullets literally fire in the opposite direction they should be.....so frustrating
	var fire_direction = Vector2.from_angle(world_angle)
	
	# DEBUG: Show all the angles and directions
	if rounds_fired % 36 == 0:  # Every 2 seconds
		print("PDC %s: FIRING DEBUG" % pdc_id.substr(4, 8))
		print("  World angle: %.1f°" % rad_to_deg(world_angle))
		print("  Fire direction: (%.2f, %.2f)" % [fire_direction.x, fire_direction.y])
		print("  Sprite rotation: %.1f°" % rad_to_deg(sprite.rotation))
		print("  Sprite global_rotation: %.1f°" % rad_to_deg(sprite.global_rotation))
		print("  Muzzle world pos: (%.1f, %.1f)" % [bullet.global_position.x, bullet.global_position.y])
		
		# Test all 4 possible directions
		var test_directions = [
			Vector2.from_angle(world_angle),                    # Current
			Vector2.from_angle(world_angle + PI),               # Opposite
			Vector2.from_angle(sprite.global_rotation),         # Sprite forward
			Vector2.from_angle(sprite.global_rotation + PI)     # Sprite backward
		]
		
		for i in range(test_directions.size()):
			var dir = test_directions[i]
			print("  Test direction %d: (%.2f, %.2f) at %.1f°" % [
				i, dir.x, dir.y, rad_to_deg(dir.angle())
			])
	
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
	
	# Original debug line
	if rounds_fired % 36 == 0:
		print("PDC %s: Fired %d rounds at %s" % [
			pdc_id.substr(4, 8), rounds_fired, current_target_id.substr(8, 7)
		])

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
		"fire_authorized": fire_authorized,
		"is_firing": is_firing,
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
		"fire_rate": rounds_per_second,
		"max_tracking_error": max_tracking_error
	}

# Set Fire Control Manager reference
func set_fire_control_manager(manager: Node):
	fire_control_manager = manager

# Emergency stop
func emergency_stop():
	stop_firing()
	emergency_slew = false
	fire_authorized = false
	current_status = "IDLE"

# Add this debug function to PDCSystem.gd to test sprite orientation
func debug_sprite_orientation():
	if not sprite:
		print("PDC %s: No sprite found!" % pdc_id)
		return
	
	print("=== PDC %s SPRITE DEBUG ===" % pdc_id)
	print("Sprite rotation: %.1f°" % rad_to_deg(sprite.rotation))
	print("Sprite global_rotation: %.1f°" % rad_to_deg(sprite.global_rotation))
	print("Parent ship rotation: %.1f°" % rad_to_deg(parent_ship.rotation))
	print("Current_rotation: %.1f°" % rad_to_deg(current_rotation))
	print("Target_rotation: %.1f°" % rad_to_deg(target_rotation))
	
	# Test: What direction is the sprite's "forward" direction?
	var sprite_forward = Vector2.UP.rotated(sprite.global_rotation)
	var sprite_angle = sprite_forward.angle()
	print("Sprite forward direction: (%.2f, %.2f) at %.1f°" % [
		sprite_forward.x, sprite_forward.y, rad_to_deg(sprite_angle)
	])
	
	# Test: What direction should we be firing?
	var desired_direction = Vector2.from_angle(current_rotation)
	print("Desired fire direction: (%.2f, %.2f) at %.1f°" % [
		desired_direction.x, desired_direction.y, rad_to_deg(current_rotation)
	])
	
	# Test: Are they aligned?
	var alignment_error = abs(angle_difference(sprite_angle, current_rotation))
	print("Sprite alignment error: %.1f°" % rad_to_deg(alignment_error))
	print("================================")
