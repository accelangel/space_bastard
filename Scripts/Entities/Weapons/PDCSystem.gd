# Scripts/Entities/Weapons/PDCSystem.gd - CLEANED UP DEBUG VERSION
extends Node2D

# PDC Hardware Configuration
@export var turret_rotation_speed: float = 90.0  # degrees/second
@export var max_rotation_speed_multiplier: float = 2.0
@export var bullet_velocity_mps: float = 1100.0
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
var rotation_pivot: Marker2D
var sprite: Sprite2D
var muzzle_point: Marker2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics for battle tracking
var rounds_fired: int = 0
var targets_hit: int = 0
var targets_missed: int = 0
var last_fire_time: float = 0.0

# MINIMAL DEBUG SYSTEM
@export var debug_enabled: bool = true  # Disabled by default
var debug_bullet_count: int = 0

# FIXED ORIENTATION CONSTANTS
const SPRITE_POINTS_UP: bool = true
const IDLE_FACES_SHIP_FORWARD: bool = true
const COORDINATE_CORRECTION: float = PI

func _ready():
	parent_ship = get_parent()
	setup_sprite_references()
	mount_position = position
	pdc_id = "PDC_%d_%d" % [int(position.x), int(position.y)]
	set_idle_rotation()
	
	# Minimal initialization log
	if debug_enabled:
		print("PDC %s initialized" % pdc_id.substr(4, 8))
	
	# DEBUG: Print exact PDC ID for comparison
	if position.x < 0:  # Only for problem PDCs
		print("🔍 PROBLEM PDC ID: '%s' at position %s" % [pdc_id, position])

func setup_sprite_references():
	rotation_pivot = get_node_or_null("RotationPivot")
	if rotation_pivot:
		sprite = rotation_pivot.get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")
	else:
		sprite = get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")

func set_idle_rotation():
	if not parent_ship:
		current_rotation = 0.0
		target_rotation = 0.0
		return
	
	if IDLE_FACES_SHIP_FORWARD:
		current_rotation = 0.0
		target_rotation = 0.0
	else:
		current_rotation = PI/2
		target_rotation = PI/2
	
	update_sprite_rotation()

func _physics_process(delta):
	# ADD THIS DEBUG LINE
	if debug_enabled and is_firing and debug_bullet_count < 10:
		print("PDC %s firing at target: %s (assigned by: %s)" % [
			pdc_id.substr(4, 8), 
			current_target_id.substr(8, 7) if current_target_id != "" else "NONE",
			"FireControl" if fire_control_manager else "UNKNOWN"
		])
	
	update_turret_rotation(delta)
	handle_firing(delta)

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
	
	update_sprite_rotation()

func update_sprite_rotation():
	if not rotation_pivot and not sprite:
		return
	
	var sprite_rotation = calculate_sprite_rotation()
	
	if rotation_pivot:
		rotation_pivot.rotation = sprite_rotation
	elif sprite:
		sprite.rotation = sprite_rotation

func calculate_sprite_rotation() -> float:
	var base_rotation = current_rotation
	
	if SPRITE_POINTS_UP:
		return base_rotation + COORDINATE_CORRECTION
	else:
		return base_rotation + PI/2 + COORDINATE_CORRECTION

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
	target_rotation = target_angle - PI/2  # Apply -90° correction
	emergency_slew = is_emergency
	fire_authorized = false
	current_status = "TRACKING"

func authorize_firing():
	if current_target_id != "" and is_aimed():
		fire_authorized = true
		current_status = "READY"

func start_firing():
	if not fire_authorized or not is_aimed():
		return
	
	is_firing = true
	current_status = "FIRING"
	fire_timer = 0.0
	last_fire_time = Time.get_ticks_msec() / 1000.0

func stop_firing():
	is_firing = false
	fire_authorized = false
	current_status = "IDLE"
	current_target_id = ""
	set_idle_rotation()

func is_aimed() -> bool:
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	return angle_diff < deg_to_rad(max_tracking_error)

func get_tracking_error() -> float:
	return abs(angle_difference(current_rotation, target_rotation))

# Replace the existing fire_bullet() function with this enhanced version:

func fire_bullet():
	if not bullet_scene:
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	bullet.global_position = get_muzzle_world_position()
	
	debug_bullet_count += 1
	
	# CORRECTED FIRE DIRECTION
	var current_rotation_for_firing = current_rotation - PI/2
	var world_angle = current_rotation_for_firing + parent_ship.rotation
	var fire_direction = Vector2.from_angle(world_angle)
	
	if debug_enabled and pdc_id in ["PDC_-4_-72", "PDC_-21_-34", "PDC_-16_-49"]:
		print("🔍 DEBUG CHECK: PDC %s should show diagnostic (bullet #%d)" % [pdc_id.substr(4, 8), debug_bullet_count])
		
	
	# ENHANCED DIAGNOSTIC for problem PDCs
	if debug_enabled and pdc_id in ["PDC_-4_-72", "PDC_-21_-34", "PDC_-16_-49"] and debug_bullet_count <= 5:
		print("\n🔫 BULLET FIRING DEBUG - PDC %s (Bullet #%d):" % [pdc_id.substr(4, 8), debug_bullet_count])
		print("  Mount position: %s" % mount_position)
		print("  Muzzle world position: %s" % get_muzzle_world_position())
		print("  Current PDC rotation: %.1f°" % rad_to_deg(current_rotation))
		print("  Firing rotation calc: %.1f°" % rad_to_deg(current_rotation_for_firing))
		print("  Ship rotation: %.1f°" % rad_to_deg(parent_ship.rotation))
		print("  World firing angle: %.1f°" % rad_to_deg(world_angle))
		print("  Fire direction vector: %s" % fire_direction)
		print("  Target: %s" % current_target_id.substr(8, 7))
		
		# Verify the fire direction makes sense
		var angle_magnitude = abs(rad_to_deg(world_angle))
		if angle_magnitude > 360:
			print("  ⚠️ WARNING: Extreme firing angle detected!")
		else:
			print("  ✓ Firing angle within normal range")
	
	var ship_velocity = get_ship_velocity()
	var bullet_velocity = fire_direction * bullet_velocity_mps + ship_velocity
	var bullet_velocity_pixels = bullet_velocity / WorldSettings.meters_per_pixel
	
	if bullet.has_method("set_velocity"):
		bullet.set_velocity(bullet_velocity_pixels)
	
	if parent_ship and "faction" in parent_ship:
		if bullet.has_method("set_faction"):
			bullet.set_faction(parent_ship.faction)
	
	if bullet.has_signal("hit_target"):
		bullet.hit_target.connect(_on_bullet_hit)
	
	rounds_fired += 1

func _on_bullet_hit():
	targets_hit += 1
	
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
	set_idle_rotation()

func get_battle_stats() -> Dictionary:
	return {
		"pdc_id": pdc_id,
		"rounds_fired": rounds_fired,
		"targets_hit": targets_hit,
		"targets_missed": targets_missed,
		"hit_rate": (float(targets_hit) / float(rounds_fired)) * 100.0 if rounds_fired > 0 else 0.0
	}

func reset_battle_stats():
	rounds_fired = 0
	targets_hit = 0
	targets_missed = 0
	debug_bullet_count = 0

# COMMENTED OUT: Debug utilities (can be re-enabled if needed)
# func print_comprehensive_debug():
#	print("PDC %s: %s | Target: %s | Rounds: %d" % [
#		pdc_id.substr(4, 8), current_status, 
#		current_target_id.substr(8, 7) if current_target_id != "" else "None",
#		rounds_fired
#	])

# func force_fire_test_bullet():
#	print("Test bullet fired from PDC %s" % pdc_id.substr(4, 8))
#	fire_bullet()
