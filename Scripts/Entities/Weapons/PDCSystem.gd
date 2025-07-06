# Scripts/Entities/Weapons/PDCSystem.gd - ROTATION FIXED VERSION
extends Node2D

# PDC Hardware Configuration
@export var turret_rotation_speed: float = 90.0  # degrees/second
@export var max_rotation_speed_multiplier: float = 2.0
@export var bullet_velocity_mps: float = 800.0
@export var rounds_per_second: float = 18.0
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
var current_status: String = "IDLE"

# Target tracking
var current_target_id: String = ""
var target_distance_meters: float = 0.0
var fire_authorized: bool = false

# References
var parent_ship: Node2D
var fire_control_manager: Node
var rotation_pivot: Marker2D  # NEW: Proper pivot point
var sprite: Sprite2D
var muzzle_point: Marker2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics for battle tracking
var rounds_fired: int = 0
var targets_hit: int = 0
var targets_missed: int = 0
var last_fire_time: float = 0.0

# Debug
var debug_enabled: bool = true
var debug_timer: float = 0.0

# SPRITE ORIENTATION CONSTANTS
# These define how your sprite is oriented in the art file
const SPRITE_FORWARD_ANGLE: float = -PI/2  # -90 degrees - sprite points "down" in art
const IDLE_ANGLE_OFFSET: float = PI/2       # FIXED: +90° offset to make idle face ship direction

func _ready():
	parent_ship = get_parent()
	
	# Find the rotation pivot (new method)
	rotation_pivot = get_node_or_null("RotationPivot")  # FIXED: Match your scene node name
	if rotation_pivot:
		sprite = rotation_pivot.get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")
	else:
		# Fallback to old method if pivot not found
		sprite = get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")
		print("PDC %s: Warning - using old rotation method, consider adding RotationPivot" % pdc_id)
	
	mount_position = position
	pdc_id = "PDC_%d_%d" % [int(position.x), int(position.y)]
	
	# Set initial rotation to match ship's forward direction
	current_rotation = IDLE_ANGLE_OFFSET
	target_rotation = IDLE_ANGLE_OFFSET
	
	print("PDC initialized: ", pdc_id, " at mount position: ", mount_position)
	
	# Connect to bullet hit signals for tracking
	if bullet_scene:
		# We'll track hits when bullets report back
		pass

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

func update_turret_rotation(delta):
	if not rotation_pivot and not sprite:
		return
	
	var angle_diff = angle_difference(current_rotation, target_rotation)
	var rotation_speed = deg_to_rad(turret_rotation_speed)
	
	if emergency_slew:
		rotation_speed *= max_rotation_speed_multiplier
	
	var rotation_step = rotation_speed * delta
	
	if abs(angle_diff) > rotation_step:
		current_rotation += sign(angle_diff) * rotation_step
	else:
		current_rotation = target_rotation
	
	# Apply rotation - NEW METHOD with proper pivot
	if rotation_pivot:
		# FIXED: Proper sprite orientation handling
		# The sprite is drawn pointing "down" (-Y), so we need to account for that
		var sprite_rotation = current_rotation - parent_ship.rotation - SPRITE_FORWARD_ANGLE
		rotation_pivot.rotation = sprite_rotation
	else:
		# Fallback to old method
		if sprite:
			sprite.rotation = current_rotation - parent_ship.rotation - SPRITE_FORWARD_ANGLE

func handle_firing(delta):
	var should_fire = (
		current_target_id != "" and 
		fire_authorized and 
		is_aimed()
	)
	
	if should_fire:
		if not is_firing:
			start_firing()
		
		if is_firing:
			fire_timer += delta
			var fire_interval = 1.0 / rounds_per_second
			
			if fire_timer >= fire_interval:
				fire_bullet()
				fire_timer = 0.0
	else:
		if is_firing:
			stop_firing()

func set_target(target_id: String, target_angle: float, is_emergency: bool = false):
	current_target_id = target_id
	target_rotation = target_angle
	emergency_slew = is_emergency
	fire_authorized = false
	
	current_status = "TRACKING"
	
	if debug_enabled:
		print("PDC %s: Tracking target %s at angle %.1f°" % [
			pdc_id.substr(4, 8), target_id.substr(8, 7), rad_to_deg(target_angle)
		])

func authorize_firing():
	if current_target_id != "" and is_aimed():
		fire_authorized = true
		current_status = "READY"
		
		if debug_enabled:
			print("PDC %s: AUTHORIZED to fire on %s" % [
				pdc_id.substr(4, 8), current_target_id.substr(8, 7)
			])

func start_firing():
	if not fire_authorized or not is_aimed():
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

func fire_bullet():
	if not bullet_scene:
		print("PDC %s: No bullet scene loaded!" % pdc_id)
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# Position at muzzle
	bullet.global_position = get_muzzle_world_position()
	
	# FIXED: Direct angle calculation instead of RotationFramework
	# current_rotation is ship-relative, convert to world angle
	var world_angle = current_rotation + parent_ship.rotation
	var fire_direction = Vector2.from_angle(world_angle)
	
	# Debug EVERY bullet for first few shots
	if rounds_fired < 5:
		print("PDC %s BULLET DEBUG #%d:" % [pdc_id.substr(4, 8), rounds_fired + 1])
		print("  Ship rotation: %.1f°" % rad_to_deg(parent_ship.rotation))
		print("  PDC current_rotation: %.1f°" % rad_to_deg(current_rotation))
		print("  World angle: %.1f°" % rad_to_deg(world_angle))
		print("  Fire direction: (%.2f, %.2f)" % [fire_direction.x, fire_direction.y])
		print("  Should be firing toward: ~105.5°")
	
	# Add ship velocity to bullet
	var ship_velocity = get_ship_velocity()
	var bullet_velocity = fire_direction * bullet_velocity_mps + ship_velocity
	var bullet_velocity_pixels = bullet_velocity / WorldSettings.meters_per_pixel
	
	if bullet.has_method("set_velocity"):
		bullet.set_velocity(bullet_velocity_pixels)
	
	# Set faction and connect hit signal
	if parent_ship and "faction" in parent_ship:
		if bullet.has_method("set_faction"):
			bullet.set_faction(parent_ship.faction)
	
	# Connect to bullet for hit tracking
	if bullet.has_signal("hit_target"):
		bullet.hit_target.connect(_on_bullet_hit)
	
	rounds_fired += 1
	
	# Debug output every 2 seconds of firing
	if rounds_fired % 36 == 0:
		print("PDC %s: Fired %d rounds at %s" % [
			pdc_id.substr(4, 8), rounds_fired, current_target_id.substr(8, 7)
		])

func _on_bullet_hit():
	targets_hit += 1
	
	# Notify Fire Control Manager
	if fire_control_manager and fire_control_manager.has_method("report_successful_intercept"):
		fire_control_manager.report_successful_intercept(pdc_id, current_target_id)

func get_muzzle_world_position() -> Vector2:
	if muzzle_point:
		return muzzle_point.global_position
	elif rotation_pivot:
		return rotation_pivot.global_position
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

# Status reporting
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
		"targets_hit": targets_hit,
		"targets_missed": targets_missed,
		"current_target": current_target_id,
		"mount_position": mount_position
	}

func get_capabilities() -> Dictionary:
	return {
		"rotation_speed": turret_rotation_speed,
		"max_rotation_speed": turret_rotation_speed * max_rotation_speed_multiplier,
		"bullet_velocity": bullet_velocity_mps,
		"fire_rate": rounds_per_second,
		"max_tracking_error": max_tracking_error
	}

func set_fire_control_manager(manager: Node):
	fire_control_manager = manager

func emergency_stop():
	stop_firing()
	emergency_slew = false
	fire_authorized = false
	current_status = "IDLE"
	current_rotation = IDLE_ANGLE_OFFSET
	target_rotation = IDLE_ANGLE_OFFSET

# NEW: Get battle statistics
func get_battle_stats() -> Dictionary:
	return {
		"pdc_id": pdc_id,
		"rounds_fired": rounds_fired,
		"targets_hit": targets_hit,
		"targets_missed": targets_missed,
		"hit_rate": (float(targets_hit) / float(rounds_fired)) * 100.0 if rounds_fired > 0 else 0.0
	}

# Reset stats for new battle
func reset_battle_stats():
	rounds_fired = 0
	targets_hit = 0
	targets_missed = 0
