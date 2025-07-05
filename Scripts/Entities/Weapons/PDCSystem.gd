# Scripts/Entities/Weapons/PDCSystem.gd - SINGLE TURRET VERSION
extends Node2D
class_name PDCSystem

# PDC Configuration
@export var bullet_velocity_mps: float = 300.0
@export var bullets_per_burst: int = 10  # Bullets in a burst
@export var burst_fire_rate: float = 20.0  # Bullets per second DURING a burst
@export var burst_cooldown: float = 0.5  # Seconds between bursts
@export var engagement_range_meters: float = 8000.0
@export var min_intercept_distance_meters: float = 500.0
@export var turret_rotation_speed: float = 3.0  # Radians per second

# Firing modes
enum FiringState { IDLE, TRACKING, FIRING, COOLDOWN }
var current_state: FiringState = FiringState.IDLE

# Current target
var current_target: Node2D = null
var burst_bullets_fired: int = 0
var cooldown_timer: float = 0.0
var fire_timer: float = 0.0

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

func _ready():
	parent_ship = get_parent()
	sprite = get_node_or_null("Sprite2D")
	
	# Find sensor system on parent ship
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
	
	print("PDC turret initialized")

func _physics_process(delta):
	if not sensor_system:
		return
	
	# Update timers
	cooldown_timer = max(0.0, cooldown_timer - delta)
	fire_timer += delta
	
	# State machine
	match current_state:
		FiringState.IDLE:
			find_new_target()
			
		FiringState.TRACKING:
			update_tracking(delta)
			
		FiringState.FIRING:
			fire_burst(delta)
			
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
		current_state = FiringState.TRACKING
		burst_bullets_fired = 0

func is_valid_target(torpedo: Node2D) -> bool:
	if not torpedo or not is_instance_valid(torpedo):
		return false
		
	var distance = global_position.distance_to(torpedo.global_position)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	if distance_meters > engagement_range_meters or distance_meters < min_intercept_distance_meters:
		return false
	
	# Check if approaching
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var to_torpedo = torpedo.global_position - global_position
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	
	return closing_speed > 10.0

func calculate_target_priority(torpedo: Node2D) -> float:
	var distance = global_position.distance_to(torpedo.global_position)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Prioritize closer targets
	var distance_factor = 1.0 - (distance_meters / engagement_range_meters)
	
	# Prioritize faster approaching targets
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var to_torpedo = torpedo.global_position - global_position
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	var speed_factor = clamp(closing_speed / 200.0, 0.0, 1.0)
	
	return distance_factor * 2.0 + speed_factor

func update_tracking(_delta):
	if not is_valid_target(current_target):
		current_state = FiringState.IDLE
		current_target = null
		return
	
	# Calculate lead angle
	var lead_angle = calculate_lead_angle(current_target)
	target_rotation = lead_angle
	
	# Check if we're aimed close enough to start firing
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	if angle_diff < 0.1:  # Within ~5.7 degrees
		current_state = FiringState.FIRING
		fire_timer = 0.0

func fire_burst(_delta):
	if not is_valid_target(current_target):
		current_state = FiringState.COOLDOWN
		cooldown_timer = burst_cooldown
		current_target = null
		return
	
	# Update aim during burst
	var lead_angle = calculate_lead_angle(current_target)
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

func calculate_lead_angle(torpedo: Node2D) -> float:
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo)
	
	# Direct angle to current torpedo position
	var to_torpedo = torpedo_pos - global_position
	
	# If torpedo is moving slowly, just aim directly at it
	if torpedo_vel.length() < 10.0:
		return to_torpedo.angle()
	
	# Calculate intercept point
	var distance = to_torpedo.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Time for bullet to reach that distance
	var bullet_travel_time = distance_meters / bullet_velocity_mps
	
	# Where torpedo will be after that time (in pixels)
	var predicted_offset = torpedo_vel * bullet_travel_time
	var predicted_pos = torpedo_pos + predicted_offset
	
	# Angle to predicted position
	var to_predicted = predicted_pos - global_position
	
	return to_predicted.angle()

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

func get_debug_info() -> String:
	var state_name = ["IDLE", "TRACKING", "FIRING", "COOLDOWN"][current_state]
	return "PDC: %s | Shots: %d | Kills: %d" % [state_name, total_shots_fired, torpedoes_destroyed]
