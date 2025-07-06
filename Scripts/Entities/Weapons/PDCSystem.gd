# Scripts/Entities/Weapons/PDCSystem.gd - FIXED VERSION WITH IMPROVED TARGET MANAGEMENT
extends Node2D
class_name PDCSystem

# PDC Configuration
@export var bullet_velocity_mps: float = 300.0
@export var bullets_per_burst: int = 100  # Bullets in a burst
@export var burst_fire_rate: float = 50.0  # Bullets per second DURING a burst
@export var burst_cooldown: float = 0.001  # Seconds between bursts
@export var engagement_range_meters: float = 15000.0
@export var min_intercept_distance_meters: float = 1.0  # Increased minimum distance
@export var turret_rotation_speed: float = 30.0  # Radians per second

# Firing modes
enum FiringState { IDLE, TRACKING, FIRING, COOLDOWN }
var current_state: FiringState = FiringState.IDLE

# Current target
var current_target: Node2D = null
var target_locked_at: float = 0.0  # When we locked onto current target
var burst_bullets_fired: int = 0
var cooldown_timer: float = 0.0
var fire_timer: float = 0.0

# Target management
var target_lock_duration: float = 2.0  # Minimum time to stick with a target
var last_target_check: float = 0.0
var target_check_interval: float = 0.1  # Check for new targets every 100ms
var game_time: float = 0.0  # Track our own time

# Turret rotation
var current_rotation: float = 0.0
var target_rotation: float = 0.0

# References
var parent_ship: Node2D
var sensor_system: SensorSystem
var sprite: Sprite2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics
var total_shots_fired: int = 0
var torpedoes_destroyed: int = 0

# Debug
var debug_intercept_pos: Vector2
var debug_current_target_pos: Vector2

func _ready():
	parent_ship = get_parent()
	sprite = get_node_or_null("Sprite2D")
	
	# Find sensor system on parent ship
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
	
	print("PDC turret initialized with improved target management")

func _physics_process(delta):
	if not sensor_system:
		return
	
	# Update our own time tracker
	game_time += delta
	
	# Update timers
	cooldown_timer = max(0.0, cooldown_timer - delta)
	fire_timer += delta
	last_target_check += delta
	
	# State machine
	match current_state:
		FiringState.IDLE:
			find_new_target()
			
		FiringState.TRACKING:
			update_tracking()
			
		FiringState.FIRING:
			fire_burst()
			
		FiringState.COOLDOWN:
			if cooldown_timer <= 0:
				current_state = FiringState.IDLE
	
	# Update turret rotation
	update_turret_rotation(delta)

func find_new_target():
	var torpedoes = sensor_system.get_all_enemy_torpedoes()
	var best_target = null
	var best_priority = -1.0
	
	for torpedo in torpedoes:
		if not is_valid_target(torpedo):
			continue
			
		var priority = calculate_target_priority(torpedo)
		if priority > best_priority:
			best_priority = priority
			best_target = torpedo
	
	if best_target:
		current_target = best_target
		target_locked_at = game_time
		current_state = FiringState.TRACKING
		burst_bullets_fired = 0
		var distance_m = global_position.distance_to(best_target.global_position) * WorldSettings.meters_per_pixel
		print("PDC acquired target at distance: %.0f meters" % distance_m)

func is_valid_target(torpedo: Node2D) -> bool:
	if not torpedo or not is_instance_valid(torpedo):
		return false
	
	# Safety check - make sure torpedo wasn't just freed
	if torpedo.is_queued_for_deletion():
		return false
	
	var torpedo_pos = torpedo.global_position
	var distance = global_position.distance_to(torpedo_pos)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Basic range check
	if distance_meters > engagement_range_meters or distance_meters < min_intercept_distance_meters:
		return false
	
	# Check if torpedo is approaching (not moving away or already passed)
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var to_torpedo = torpedo_pos - global_position
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	
	# Reject if torpedo is moving away or too slow
	if closing_speed < 10.0:
		return false
	
	# CRITICAL: Check if torpedo is behind us or at extreme angles
	var ship_forward = Vector2.from_angle(parent_ship.rotation) if parent_ship else Vector2.RIGHT
	var to_torpedo_normalized = to_torpedo.normalized()
	var angle_to_torpedo = ship_forward.angle_to(to_torpedo_normalized)
	
	# Reject targets that are more than 160 degrees off our front arc
	if abs(angle_to_torpedo) > deg_to_rad(160):
		return false
	
	# Extra check: Don't target torpedoes that are very close and moving perpendicular
	if distance_meters < 500.0:
		var perpendicular_speed = abs(torpedo_vel.dot(to_torpedo.normalized().orthogonal()))
		if perpendicular_speed > closing_speed * 2.0:
			return false  # Torpedo is mostly moving sideways, probably already past us
	
	return true

func calculate_target_priority(torpedo: Node2D) -> float:
	var torpedo_pos = torpedo.global_position
	var distance = global_position.distance_to(torpedo_pos)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Base priority on distance (closer = higher priority)
	var distance_factor = 1.0 - (distance_meters / engagement_range_meters)
	
	# Factor in approach speed
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var to_torpedo = torpedo_pos - global_position
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	var speed_factor = clamp(closing_speed / 200.0, 0.0, 1.0)
	
	# Factor in angle - prefer targets in front
	var ship_forward = Vector2.from_angle(parent_ship.rotation) if parent_ship else Vector2.RIGHT
	var angle_factor = max(0.0, ship_forward.dot(to_torpedo.normalized()))
	
	# Factor in intercept feasibility
	var intercept_factor = 1.0
	var intercept_time = estimate_intercept_time(torpedo)
	if intercept_time > 5.0 or intercept_time < 0.1:
		intercept_factor = 0.1  # Very hard to intercept
	
	return distance_factor * 3.0 + speed_factor * 2.0 + angle_factor * 1.0 + intercept_factor * 2.0

func estimate_intercept_time(torpedo: Node2D) -> float:
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo) / WorldSettings.meters_per_pixel
	var distance = global_position.distance_to(torpedo_pos)
	var bullet_speed = bullet_velocity_mps / WorldSettings.meters_per_pixel
	
	# Simple estimate based on closing speed
	var closing_speed = torpedo_vel.dot((global_position - torpedo_pos).normalized())
	var net_approach_speed = bullet_speed + closing_speed
	
	if net_approach_speed <= 0:
		return 999.0  # Can't intercept
	
	return distance / net_approach_speed

func update_tracking():
	# Check if current target is still valid
	if not is_valid_target(current_target):
		print("PDC lost target - invalid")
		current_state = FiringState.IDLE
		current_target = null
		return
	
	# Periodically check for better targets, but only if we haven't been locked long
	var time_locked = game_time - target_locked_at
	
	if time_locked > target_lock_duration and last_target_check > target_check_interval:
		last_target_check = 0.0
		
		# Only switch if we find a MUCH better target
		var current_priority = calculate_target_priority(current_target)
		var torpedoes = sensor_system.get_all_enemy_torpedoes()
		
		for torpedo in torpedoes:
			if torpedo == current_target or not is_valid_target(torpedo):
				continue
			
			var priority = calculate_target_priority(torpedo)
			if priority > current_priority * 1.5:  # Must be 50% better to switch
				print("PDC switching to higher priority target")
				current_target = torpedo
				target_locked_at = game_time
				break
	
	# Calculate lead angle
	var lead_angle = calculate_lead_angle_simple(current_target)
	target_rotation = lead_angle
	
	# Check if we're aimed close enough to start firing
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	if angle_diff < 0.1:  # Within ~5.7 degrees
		current_state = FiringState.FIRING
		fire_timer = 0.0

func fire_burst():
	# Continuously validate target during burst
	if not is_valid_target(current_target):
		print("PDC target lost during burst")
		current_state = FiringState.COOLDOWN
		cooldown_timer = burst_cooldown
		current_target = null
		return
	
	# Update aim during burst (but don't switch targets)
	var lead_angle = calculate_lead_angle_simple(current_target)
	target_rotation = lead_angle
	
	# Fire bullets at the burst rate
	var bullet_interval = 1.0 / burst_fire_rate
	if fire_timer >= bullet_interval and burst_bullets_fired < bullets_per_burst:
		fire_bullet()
		burst_bullets_fired += 1
		fire_timer = 0.0
	
	# Check if burst is complete
	if burst_bullets_fired >= bullets_per_burst:
		current_state = FiringState.COOLDOWN
		cooldown_timer = burst_cooldown
		burst_bullets_fired = 0

func fire_bullet():
	if not bullet_scene:
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# Position at turret location
	bullet.global_position = global_position
	
	# Fire in turret direction with small random spread
	var spread = randf_range(-0.02, 0.02)  # ~1 degree spread
	var fire_direction = Vector2.from_angle(current_rotation + spread)
	
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
	
	# Track intercepts
	if bullet.has_signal("hit_target"):
		bullet.hit_target.connect(_on_torpedo_intercepted)
	
	total_shots_fired += 1

func calculate_lead_angle_simple(torpedo: Node2D) -> float:
	var torpedo_pos = torpedo.global_position
	var torpedo_vel_mps = get_torpedo_velocity(torpedo)
	
	# If torpedo is barely moving, aim directly at it
	if torpedo_vel_mps.length() < 5.0:
		return (torpedo_pos - global_position).angle()
	
	# Convert to pixels/second for consistency
	var torpedo_vel_pixels = torpedo_vel_mps / WorldSettings.meters_per_pixel
	var ship_vel_pixels = get_ship_velocity() / WorldSettings.meters_per_pixel
	var bullet_speed_pixels = bullet_velocity_mps / WorldSettings.meters_per_pixel
	
	# Simple time-to-intercept estimation
	var initial_distance = global_position.distance_to(torpedo_pos)
	var closing_speed = torpedo_vel_pixels.dot((global_position - torpedo_pos).normalized())
	var net_approach_speed = bullet_speed_pixels + closing_speed
	
	# Prevent division by zero
	if net_approach_speed <= 0:
		return (torpedo_pos - global_position).angle()
	
	# Estimate intercept time
	var estimated_time = initial_distance / net_approach_speed
	
	# Clamp time to reasonable values
	estimated_time = clamp(estimated_time, 0.1, 8.0)
	
	# Calculate predicted intercept position
	var predicted_torpedo_pos = torpedo_pos + torpedo_vel_pixels * estimated_time
	var predicted_ship_pos = global_position + ship_vel_pixels * estimated_time
	
	# Aim at predicted position
	var to_intercept = predicted_torpedo_pos - predicted_ship_pos
	return to_intercept.angle()

func update_turret_rotation(delta):
	if sprite:
		# Smoothly rotate turret toward target
		var angle_diff = angle_difference(current_rotation, target_rotation)
		var rotation_step = turret_rotation_speed * delta
		
		if abs(angle_diff) > rotation_step:
			current_rotation += sign(angle_diff) * rotation_step
		else:
			current_rotation = target_rotation
		
		sprite.rotation = current_rotation

func angle_difference(from: float, to: float) -> float:
	var diff = fmod(to - from, TAU)
	if diff > PI:
		diff -= TAU
	elif diff < -PI:
		diff += TAU
	return diff

func get_torpedo_velocity(torpedo: Node2D) -> Vector2:
	if torpedo.has_method("get_velocity_mps"):
		return torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		return torpedo.velocity_mps
	return Vector2.ZERO

func get_ship_velocity() -> Vector2:
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		return parent_ship.get_velocity_mps()
	return Vector2.ZERO

func _on_torpedo_intercepted():
	torpedoes_destroyed += 1
	print("PDC destroyed torpedo! Total: ", torpedoes_destroyed)
	
	# Don't immediately clear target - let normal validation handle it
	# This prevents the "shooting backwards" issue

func get_debug_info() -> String:
	var state_name = ["IDLE", "TRACKING", "FIRING", "COOLDOWN"][current_state]
	var target_info = "None"
	if current_target:
		var dist = global_position.distance_to(current_target.global_position) * WorldSettings.meters_per_pixel
		target_info = "%.0fm" % dist
	return "PDC: %s | Target: %s | Shots: %d | Kills: %d" % [state_name, target_info, total_shots_fired, torpedoes_destroyed]
