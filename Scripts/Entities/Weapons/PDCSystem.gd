# Scripts/Entities/Weapons/PDCSystem.gd - COMPREHENSIVE DEBUG & FIX VERSION
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

# ENHANCED DEBUG SYSTEM
@export var debug_enabled: bool = true
@export var debug_verbose: bool = true
@export var debug_fire_vectors: bool = true  # Make sure this is true!
var debug_timer: float = 0.0
var debug_bullet_count: int = 0

# Add a simple flag to force debug output
var force_debug_first_bullets: bool = true

# FIXED ORIENTATION CONSTANTS
# These need to match your actual sprite orientation in the art files
const SPRITE_POINTS_UP: bool = true  # Set to true if your PDC sprite points up in the art file
const IDLE_FACES_SHIP_FORWARD: bool = true  # PDCs should face same direction as ship when idle

# COORDINATE SYSTEM CORRECTION
# The issue: Godot's coordinate system vs expected behavior
const COORDINATE_CORRECTION: float = PI  # 180° correction for backwards behavior

func _ready():
	parent_ship = get_parent()
	
	# Find the rotation pivot and sprite hierarchy
	setup_sprite_references()
	
	mount_position = position
	pdc_id = "PDC_%d_%d" % [int(position.x), int(position.y)]
	
	# FIXED: Set initial rotation based on ship's current orientation
	set_idle_rotation()
	
	print("=== PDC INITIALIZATION DEBUG ===")
	print("PDC ID: %s" % pdc_id)
	print("Mount position: %s" % str(mount_position))
	var ship_name = ""
	if parent_ship:
		ship_name = str(parent_ship.name)
	else:
		ship_name = "None"
	print("Parent ship: %s" % ship_name)
	var ship_rotation_deg = rad_to_deg(parent_ship.rotation) if parent_ship else 0.0
	print("Parent ship rotation: %.1f°" % ship_rotation_deg)
	print("Sprite setup: Pivot=%s, Sprite=%s, Muzzle=%s" % [
		rotation_pivot != null, sprite != null, muzzle_point != null
	])
	print("Initial idle rotation set to: %.1f°" % rad_to_deg(current_rotation))
	print("=================================")

func setup_sprite_references():
	"""Find and validate all sprite hierarchy references"""
	rotation_pivot = get_node_or_null("RotationPivot")
	if rotation_pivot:
		sprite = rotation_pivot.get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")
	else:
		# Fallback to old method
		sprite = get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")
	
	if debug_enabled:
		print("PDC %s sprite setup:" % pdc_id)
		print("  RotationPivot: %s" % (rotation_pivot != null))
		print("  Sprite2D: %s" % (sprite != null))
		print("  MuzzlePoint: %s" % (muzzle_point != null))

func set_idle_rotation():
	"""Set PDC to face the same direction as the ship when idle"""
	if not parent_ship:
		current_rotation = 0.0
		target_rotation = 0.0
		return
	
	if IDLE_FACES_SHIP_FORWARD:
		# PDC should face the same direction as the ship
		# FIXED: Account for coordinate system issues
		current_rotation = 0.0  # This should make PDC face same direction as ship
		target_rotation = 0.0
	else:
		# Alternative: some specific offset
		current_rotation = PI/2  # 90 degrees
		target_rotation = PI/2
	
	# Apply the rotation immediately
	update_sprite_rotation()

func _physics_process(delta):
	update_turret_rotation(delta)
	handle_firing(delta)
	
	# Enhanced debug output
	if debug_enabled:
		debug_timer += delta
		if debug_timer >= 2.0:
			debug_timer = 0.0
			print_comprehensive_debug()

func print_comprehensive_debug():
	"""Print detailed debug information about PDC state"""
	if current_status == "IDLE":
		return  # Don't spam when idle
	
	print("\n=== PDC %s DEBUG STATUS ===" % pdc_id.substr(4, 8))
	print("Status: %s | Target: %s" % [current_status, current_target_id.substr(8, 7) if current_target_id != "" else "None"])
	var ship_rotation_deg = rad_to_deg(parent_ship.rotation) if parent_ship else 0.0
	print("Ship rotation: %.1f°" % ship_rotation_deg)
	print("PDC current rotation: %.1f°" % rad_to_deg(current_rotation))
	print("PDC target rotation: %.1f°" % rad_to_deg(target_rotation))
	print("Tracking error: %.1f°" % rad_to_deg(get_tracking_error()))
	print("Fire authorized: %s | Is firing: %s" % [fire_authorized, is_firing])
	print("Rounds fired this engagement: %d" % rounds_fired)
	
	# Calculate and show what world angle this would fire at
	var ship_rotation_for_calc = parent_ship.rotation if parent_ship else 0.0
	var world_angle = current_rotation + ship_rotation_for_calc
	print("Calculated world fire angle: %.1f°" % rad_to_deg(world_angle))
	print("Fire direction vector: (%.3f, %.3f)" % [cos(world_angle), sin(world_angle)])
	print("============================\n")

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
	"""Apply current rotation to the sprite with proper orientation handling"""
	if not rotation_pivot and not sprite:
		return
	
	# Calculate the sprite rotation needed
	var sprite_rotation = calculate_sprite_rotation()
	
	# Apply rotation to the appropriate node
	if rotation_pivot:
		rotation_pivot.rotation = sprite_rotation
	elif sprite:
		sprite.rotation = sprite_rotation
	
	# Debug the rotation application
	if debug_verbose and debug_bullet_count < 3:
		var ship_rotation_deg = rad_to_deg(parent_ship.rotation) if parent_ship else 0.0
		print("PDC %s rotation update:" % pdc_id.substr(4, 8))
		print("  current_rotation (ship-relative): %.1f°" % rad_to_deg(current_rotation))
		print("  parent_ship.rotation: %.1f°" % ship_rotation_deg)
		print("  calculated sprite_rotation: %.1f°" % rad_to_deg(sprite_rotation))

func calculate_sprite_rotation() -> float:
	"""Calculate the rotation needed for the sprite based on current state"""
	# current_rotation is ship-relative angle where PDC should point
	# We need to convert this to a sprite rotation that accounts for:
	# 1. Ship's current rotation
	# 2. How the sprite is drawn in the art file
	# 3. Coordinate system corrections
	
	var base_rotation = current_rotation
	
	# EXPERIMENTAL: Try different corrections based on observed behavior
	if SPRITE_POINTS_UP:
		# If sprite points up in art file, but behavior is backwards, add correction
		return base_rotation + COORDINATE_CORRECTION
	else:
		# If sprite points in different direction, add offset
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
	
	# THE PROBLEM: target_angle might be wrong by 90°
	# Let's test different corrections for the target angle
	var corrected_angle_v1 = target_angle  # Original
	var corrected_angle_v2 = target_angle - PI/2  # -90°
	var corrected_angle_v3 = target_angle + PI/2  # +90°
	
	# Try -90° correction first (since PDCs turn 90° clockwise wrongly)
	target_rotation = corrected_angle_v2
	emergency_slew = is_emergency
	fire_authorized = false
	
	current_status = "TRACKING"
	
	if debug_enabled:
		print("PDC %s: TARGET ANGLE DEBUG" % pdc_id.substr(4, 8))
		print("  Original target_angle: %.1f°" % rad_to_deg(target_angle))
		print("  v1 (original): %.1f°" % rad_to_deg(corrected_angle_v1))
		print("  v2 (-90°): %.1f°" % rad_to_deg(corrected_angle_v2))
		print("  v3 (+90°): %.1f°" % rad_to_deg(corrected_angle_v3))
		print("  USING: v2 (-90° correction)")
		print("  Final target_rotation: %.1f°" % rad_to_deg(target_rotation))

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
	var old_target = current_target_id
	current_target_id = ""
	
	# Return to idle position when not firing
	set_idle_rotation()
	
	if debug_enabled and rounds_fired > 0:
		print("PDC %s: FIRING STOPPED on %s (fired %d rounds)" % [
			pdc_id.substr(4, 8), old_target.substr(8, 7) if old_target != "" else "unknown", rounds_fired
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
	
	# COMPREHENSIVE FIRE DIRECTION DEBUG WITH CORRECTIONS
	debug_bullet_count += 1
	
	# Calculate world firing angle - FIX THE OVERCORRECTION
	# We need to go -90° from where we currently are (which is +90° too much)
	var current_rotation_for_firing = current_rotation - PI/2  # SUBTRACT 90° instead of adding
	
	var world_angle_v1 = current_rotation_for_firing + parent_ship.rotation  # Corrected back
	var world_angle_v2 = current_rotation + parent_ship.rotation + PI  # Original + 180°
	var world_angle_v3 = current_rotation + parent_ship.rotation - PI  # Original - 180°
	var world_angle_v4 = current_rotation + parent_ship.rotation  # Back to original
	
	# Use the corrected version
	var world_angle = world_angle_v1  # This should now fire where PDC points
	var fire_direction = Vector2.from_angle(world_angle)
	
	# Quick test to confirm which correction is being used
	if debug_bullet_count == 1:
		print("*** FIRE DIRECTION: Fixed overcorrection (-90° instead of +90°) ***")
		print("*** Should now fire where PDC barrel is pointing ***")
	
	# ENHANCED DEBUG FOR FIRST 3 BULLETS - FORCED OUTPUT
	if (debug_fire_vectors and debug_bullet_count <= 3) or force_debug_first_bullets:
		print("\n*** FIRE DIRECTION CORRECTION: Using v2 (+180°) ***")
		print("*** If bullets go wrong direction, try changing to v1, v3, or v4 ***")
		print("\n=== BULLET #%d FIRE DEBUG (PDC %s) ===" % [debug_bullet_count, pdc_id.substr(4, 8)])
		print("SHIP STATE:")
		print("  ship.global_position: %s" % parent_ship.global_position)
		print("  ship.rotation: %.3f rad (%.1f°)" % [parent_ship.rotation, rad_to_deg(parent_ship.rotation)])
		print("PDC STATE:")
		print("  pdc.global_position: %s" % global_position)
		print("  pdc.current_rotation: %.3f rad (%.1f°)" % [current_rotation, rad_to_deg(current_rotation)])
		print("  pdc.target_rotation: %.3f rad (%.1f°)" % [target_rotation, rad_to_deg(target_rotation)])
		print("FIRING CALCULATION ATTEMPTS:")
		print("  v1 (corrected -90°): %.3f rad (%.1f°) -> %s" % [world_angle_v1, rad_to_deg(world_angle_v1), describe_direction(world_angle_v1)])
		print("  v2 (original +180°): %.3f rad (%.1f°) -> %s" % [world_angle_v2, rad_to_deg(world_angle_v2), describe_direction(world_angle_v2)])
		print("  v3 (original -180°): %.3f rad (%.1f°) -> %s" % [world_angle_v3, rad_to_deg(world_angle_v3), describe_direction(world_angle_v3)])
		print("  v4 (back to original): %.3f rad (%.1f°) -> %s" % [world_angle_v4, rad_to_deg(world_angle_v4), describe_direction(world_angle_v4)])
		print("USING: v1 (fixed overcorrection)")
		print("  current_rotation: %.1f°" % rad_to_deg(current_rotation))
		print("  current_rotation_for_firing: %.1f°" % rad_to_deg(current_rotation_for_firing))
		print("  world_angle = %.3f rad (%.1f°)" % [world_angle, rad_to_deg(world_angle)])
		print("  fire_direction = (%.3f, %.3f)" % [fire_direction.x, fire_direction.y])
		print("EXPECTED vs ACTUAL:")
		print("  Expected direction: toward ~105.5° (southeast)")
		print("  Actual direction: %.1f° (%s)" % [rad_to_deg(world_angle), describe_direction(world_angle)])
		print("  MATCH: %s" % ("YES!" if abs(rad_to_deg(world_angle) - 105.5) < 10 else "NO - WRONG DIRECTION"))
		print("SPRITE ROTATION DEBUG:")
		print("  sprite rotation applied: %.1f°" % rad_to_deg(calculate_sprite_rotation()))
		print("  COORDINATE_CORRECTION: %.1f°" % rad_to_deg(COORDINATE_CORRECTION))
		print("=======================================\n")
		
		# Turn off forced debug after first bullet from each PDC
		if debug_bullet_count >= 1:
			force_debug_first_bullets = false
	
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
	
	# Regular firing debug
	if rounds_fired % 36 == 0:
		print("PDC %s: Fired %d rounds at %s" % [
			pdc_id.substr(4, 8), rounds_fired, current_target_id.substr(8, 7)
		])

func describe_direction(angle: float) -> String:
	"""Convert angle to human-readable direction"""
	var deg = rad_to_deg(angle)
	if deg < 0:
		deg += 360
	
	if deg >= 337.5 or deg < 22.5:
		return "east"
	elif deg < 67.5:
		return "northeast"
	elif deg < 112.5:
		return "north"
	elif deg < 157.5:
		return "northwest"
	elif deg < 202.5:
		return "west"
	elif deg < 247.5:
		return "southwest"
	elif deg < 292.5:
		return "south"
	else:
		return "southeast"

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
	set_idle_rotation()

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
	debug_bullet_count = 0

# DEBUG UTILITIES
func print_sprite_hierarchy():
	"""Debug function to print the entire sprite hierarchy"""
	print("=== PDC %s SPRITE HIERARCHY ===" % pdc_id)
	print("PDC Node: %s" % self)
	print("  - RotationPivot: %s" % rotation_pivot)
	if rotation_pivot:
		print("    - Sprite2D: %s" % sprite)
		if sprite:
			print("      - MuzzlePoint: %s" % muzzle_point)
	else:
		print("  - Sprite2D (direct): %s" % sprite)
		if sprite:
			print("    - MuzzlePoint: %s" % muzzle_point)
	print("===============================")

func force_fire_test_bullet():
	"""Debug function to fire a test bullet in the current direction"""
	print("=== FIRING TEST BULLET ===")
	print("Current PDC state before test fire:")
	print_comprehensive_debug()
	fire_bullet()
	print("===========================")

# Add these methods for external debugging
func get_current_world_angle() -> float:
	"""Get the current world angle this PDC is pointing"""
	return current_rotation + (parent_ship.rotation if parent_ship else 0.0)

func get_expected_target_world_angle() -> float:
	"""Get the world angle this PDC should be pointing at its target"""
	return target_rotation + (parent_ship.rotation if parent_ship else 0.0)
