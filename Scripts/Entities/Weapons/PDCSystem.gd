# Scripts/Entities/Weapons/PDCSystem.gd - IMPROVED VERSION WITH DUAL-MODE ENGAGEMENT
extends Node2D

# PDC Configuration
@export var bullet_velocity_mps: float = 800.0  # Increased from 300
@export var bullets_per_burst: int = 150  # Increased burst size
@export var burst_fire_rate: float = 60.0  # Bullets per second DURING a burst
@export var burst_cooldown: float = 0.05  # Reduced cooldown between bursts
@export var engagement_range_meters: float = 15000.0
@export var min_intercept_distance_meters: float = 5.0
@export var turret_rotation_speed: float = 45.0  # Increased rotation speed

# NEW: Dual-mode engagement system
enum EngagementMode { AREA_SATURATION, DIRECT_TARGETING }
var current_mode: EngagementMode = EngagementMode.AREA_SATURATION
@export var saturation_range_meters: float = 3000.0  # Switch to direct targeting at this range
@export var saturation_fire_rate: float = 80.0  # Higher fire rate for saturation
@export var direct_fire_rate: float = 100.0  # Even higher for direct targeting
@export var target_lock_duration: float = 1.5  # Stick with target longer in direct mode

# Firing state management
enum FiringState { IDLE, TRACKING, FIRING, COOLDOWN }
var current_state: FiringState = FiringState.IDLE

# Target management - improved for rapid salvos
var current_target: Node2D = null
var target_locked_at: float = 0.0
var burst_bullets_fired: int = 0
var cooldown_timer: float = 0.0
var fire_timer: float = 0.0
var game_time: float = 0.0

# NEW: Target persistence for rapid salvos
var target_switch_cooldown: float = 0.5  # Minimum time before switching targets
var last_target_switch: float = 0.0
var high_threat_mode: bool = false  # Activated when multiple close targets detected

# Turret rotation and positioning
var current_rotation: float = 0.0
var target_rotation: float = 0.0
var default_rotation: float = 0.0  # PDC's default facing direction

# References and positioning - FIXED
var parent_ship: Node2D
var sensor_system: SensorSystem
var sprite: Sprite2D
var muzzle_point: Marker2D  # NEW: Proper muzzle point reference

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics
var total_shots_fired: int = 0
var torpedoes_destroyed: int = 0

# NEW: Area saturation variables
var saturation_target_point: Vector2
var saturation_spread: float = 0.05  # Radians of spread for area saturation

func _ready():
	parent_ship = get_parent()
	sprite = get_node_or_null("Sprite2D")
	
	# NEW: Find muzzle point properly
	if sprite:
		muzzle_point = sprite.get_node_or_null("MuzzlePoint")
		default_rotation = sprite.rotation  # Store default rotation
		current_rotation = default_rotation
	
	# Find sensor system on parent ship
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
	
	print("PDC turret initialized with dual-mode engagement system")

func _physics_process(delta):
	if not sensor_system:
		return
	
	game_time += delta
	cooldown_timer = max(0.0, cooldown_timer - delta)
	fire_timer += delta
	
	# Assess threat level and choose engagement mode
	assess_threat_level()
	
	# State machine
	match current_state:
		FiringState.IDLE:
			find_optimal_target()
			
		FiringState.TRACKING:
			update_tracking()
			
		FiringState.FIRING:
			execute_firing_mode()
			
		FiringState.COOLDOWN:
			if cooldown_timer <= 0:
				current_state = FiringState.IDLE
	
	# Update turret rotation
	update_turret_rotation(delta)

func assess_threat_level():
	var torpedoes = sensor_system.get_all_enemy_torpedoes()
	var close_torpedoes = 0
	var very_close_torpedoes = 0
	
	var pdc_world_pos = get_muzzle_world_position()
	
	for torpedo in torpedoes:
		if not is_valid_target(torpedo):
			continue
			
		var distance_m = pdc_world_pos.distance_to(torpedo.global_position) * WorldSettings.meters_per_pixel
		
		if distance_m < saturation_range_meters:
			close_torpedoes += 1
		if distance_m < saturation_range_meters * 0.5:
			very_close_torpedoes += 1
	
	# Activate high threat mode if multiple close targets
	high_threat_mode = (close_torpedoes >= 3 or very_close_torpedoes >= 2)
	
	# Choose engagement mode based on threat assessment
	if high_threat_mode and close_torpedoes > 0:
		current_mode = EngagementMode.DIRECT_TARGETING
	else:
		current_mode = EngagementMode.AREA_SATURATION

func find_optimal_target():
	var torpedoes = sensor_system.get_all_enemy_torpedoes()
	var best_target = null
	var best_priority = -1.0
	
	var pdc_world_pos = get_muzzle_world_position()
	
	# In high threat mode, prefer closer targets and be less picky
	for torpedo in torpedoes:
		if not is_valid_target(torpedo):
			continue
		
		var priority = calculate_target_priority(torpedo, pdc_world_pos)
		
		# In high threat mode, boost priority of very close targets
		if high_threat_mode:
			var distance_m = pdc_world_pos.distance_to(torpedo.global_position) * WorldSettings.meters_per_pixel
			if distance_m < saturation_range_meters * 0.3:
				priority *= 2.0  # Double priority for very close targets
		
		if priority > best_priority:
			best_priority = priority
			best_target = torpedo
	
	if best_target:
		# Check target switching cooldown unless in high threat mode
		if current_target != best_target:
			var time_since_switch = game_time - last_target_switch
			var min_switch_time = target_switch_cooldown
			
			# Reduce switch cooldown in high threat mode
			if high_threat_mode:
				min_switch_time *= 0.3
			
			# Only switch if enough time has passed or much better target found
			if time_since_switch >= min_switch_time or best_priority > calculate_target_priority(current_target, pdc_world_pos) * 2.0:
				current_target = best_target
				target_locked_at = game_time
				last_target_switch = game_time
				current_state = FiringState.TRACKING
				burst_bullets_fired = 0
				
				var distance_m = pdc_world_pos.distance_to(best_target.global_position) * WorldSettings.meters_per_pixel
				print("PDC acquired target at distance: %.0f meters" % distance_m)
		else:
			# Same target, just continue
			current_state = FiringState.TRACKING

func is_valid_target(torpedo: Node2D) -> bool:
	if not torpedo or not is_instance_valid(torpedo) or torpedo.is_queued_for_deletion():
		return false
	
	var pdc_world_pos = get_muzzle_world_position()
	var torpedo_pos = torpedo.global_position
	var distance = pdc_world_pos.distance_to(torpedo_pos)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Basic range check
	if distance_meters > engagement_range_meters or distance_meters < min_intercept_distance_meters:
		return false
	
	# Check if torpedo is approaching
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var to_torpedo = torpedo_pos - pdc_world_pos
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	
	# More lenient in high threat mode
	var min_closing_speed = 5.0 if high_threat_mode else 10.0
	if closing_speed < min_closing_speed:
		return false
	
	# Less strict angle checking in high threat mode
	var ship_forward = Vector2.from_angle(parent_ship.rotation) if parent_ship else Vector2.RIGHT
	var to_torpedo_normalized = to_torpedo.normalized()
	var angle_to_torpedo = ship_forward.angle_to(to_torpedo_normalized)
	
	var max_angle = deg_to_rad(170) if high_threat_mode else deg_to_rad(160)
	if abs(angle_to_torpedo) > max_angle:
		return false
	
	return true

func calculate_target_priority(torpedo: Node2D, pdc_pos: Vector2) -> float:
	if not torpedo or not is_instance_valid(torpedo):
		return 0.0
		
	var torpedo_pos = torpedo.global_position
	var distance = pdc_pos.distance_to(torpedo_pos)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Base priority on distance (closer = higher priority)
	var distance_factor = 1.0 - (distance_meters / engagement_range_meters)
	
	# Factor in approach speed
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var to_torpedo = torpedo_pos - pdc_pos
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	var speed_factor = clamp(closing_speed / 200.0, 0.0, 1.0)
	
	# Factor in engagement mode
	var mode_factor = 1.0
	if current_mode == EngagementMode.DIRECT_TARGETING:
		# In direct mode, heavily prioritize very close targets
		if distance_meters < saturation_range_meters * 0.5:
			mode_factor = 3.0
	
	# Factor in intercept feasibility
	var intercept_factor = 1.0
	var intercept_time = estimate_intercept_time(torpedo, pdc_pos)
	if intercept_time > 8.0 or intercept_time < 0.05:
		intercept_factor = 0.1
	
	return distance_factor * 3.0 + speed_factor * 2.0 + mode_factor * 2.0 + intercept_factor * 1.0

func update_tracking():
	if not is_valid_target(current_target):
		print("PDC lost target - invalid")
		current_state = FiringState.IDLE
		current_target = null
		return
	
	# Calculate aim point based on current mode
	if current_mode == EngagementMode.AREA_SATURATION:
		# Aim at predicted intercept area with some spread
		var lead_angle = calculate_area_saturation_angle(current_target)
		target_rotation = lead_angle
	else:
		# Direct targeting mode - precise intercept
		var lead_angle = calculate_direct_intercept_angle(current_target)
		target_rotation = lead_angle
	
	# Check if we're aimed close enough to start firing
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	var max_angle_diff = 0.15 if current_mode == EngagementMode.DIRECT_TARGETING else 0.2
	
	if angle_diff < max_angle_diff:
		current_state = FiringState.FIRING
		fire_timer = 0.0

func execute_firing_mode():
	if not is_valid_target(current_target):
		print("PDC target lost during burst")
		current_state = FiringState.COOLDOWN
		cooldown_timer = burst_cooldown
		current_target = null
		return
	
	# Update aim during burst
	if current_mode == EngagementMode.AREA_SATURATION:
		var lead_angle = calculate_area_saturation_angle(current_target)
		target_rotation = lead_angle
	else:
		var lead_angle = calculate_direct_intercept_angle(current_target)
		target_rotation = lead_angle
	
	# Choose fire rate based on mode
	var effective_fire_rate = saturation_fire_rate
	if current_mode == EngagementMode.DIRECT_TARGETING:
		effective_fire_rate = direct_fire_rate
	
	# Fire bullets at the appropriate rate
	var bullet_interval = 1.0 / effective_fire_rate
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
	
	# FIXED: Position at muzzle point, not PDC origin
	var muzzle_world_pos = get_muzzle_world_position()
	bullet.global_position = muzzle_world_pos
	
	# Calculate fire direction with appropriate spread
	var spread = 0.0
	if current_mode == EngagementMode.AREA_SATURATION:
		spread = randf_range(-saturation_spread, saturation_spread)
	else:
		spread = randf_range(-0.01, 0.01)  # Tighter spread for direct targeting
	
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

func calculate_area_saturation_angle(torpedo: Node2D) -> float:
	# Calculate where torpedo will be in near future and aim there
	var torpedo_pos = torpedo.global_position
	var torpedo_vel_mps = get_torpedo_velocity(torpedo)
	var pdc_world_pos = get_muzzle_world_position()
	
	# Predict torpedo position 1-2 seconds ahead
	var prediction_time = 1.5
	var torpedo_vel_pixels = torpedo_vel_mps / WorldSettings.meters_per_pixel
	var predicted_pos = torpedo_pos + torpedo_vel_pixels * prediction_time
	
	# Aim at the predicted area
	var to_predicted = predicted_pos - pdc_world_pos
	return to_predicted.angle()

func calculate_direct_intercept_angle(torpedo: Node2D) -> float:
	# More precise intercept calculation for direct targeting
	var torpedo_pos = torpedo.global_position
	var torpedo_vel_mps = get_torpedo_velocity(torpedo)
	var pdc_world_pos = get_muzzle_world_position()
	
	if torpedo_vel_mps.length() < 5.0:
		return (torpedo_pos - pdc_world_pos).angle()
	
	var torpedo_vel_pixels = torpedo_vel_mps / WorldSettings.meters_per_pixel
	var ship_vel_pixels = get_ship_velocity() / WorldSettings.meters_per_pixel
	var bullet_speed_pixels = bullet_velocity_mps / WorldSettings.meters_per_pixel
	
	# Calculate intercept point
	var intercept_point = calculate_intercept_point(pdc_world_pos, ship_vel_pixels, torpedo_pos, torpedo_vel_pixels, bullet_speed_pixels)
	
	var to_intercept = intercept_point - pdc_world_pos
	return to_intercept.angle()

func calculate_intercept_point(shooter_pos: Vector2, shooter_vel: Vector2, target_pos: Vector2, target_vel: Vector2, bullet_speed: float) -> Vector2:
	var relative_pos = target_pos - shooter_pos
	var relative_vel = target_vel - shooter_vel
	
	if relative_vel.length() < 1.0:
		return target_pos
	
	var a = relative_vel.dot(relative_vel) - bullet_speed * bullet_speed
	var b = 2.0 * relative_pos.dot(relative_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	if discriminant < 0.0 or abs(a) < 0.01:
		return target_pos
	
	var t1 = (-b + sqrt(discriminant)) / (2.0 * a)
	var t2 = (-b - sqrt(discriminant)) / (2.0 * a)
	
	var intercept_time = 0.0
	if t1 > 0 and t2 > 0:
		intercept_time = min(t1, t2)
	elif t1 > 0:
		intercept_time = t1
	elif t2 > 0:
		intercept_time = t2
	else:
		return target_pos
	
	return target_pos + target_vel * intercept_time

func update_turret_rotation(delta):
	if sprite:
		# Smoothly rotate turret toward target
		var angle_diff = angle_difference(current_rotation, target_rotation)
		var rotation_step = turret_rotation_speed * delta
		
		if abs(angle_diff) > rotation_step:
			current_rotation += sign(angle_diff) * rotation_step
		else:
			current_rotation = target_rotation
		
		# FIXED: Apply rotation to sprite correctly
		sprite.rotation = current_rotation

func get_muzzle_world_position() -> Vector2:
	# FIXED: Calculate actual muzzle position in world space
	if muzzle_point:
		return muzzle_point.global_position
	else:
		# Fallback to PDC center if no muzzle point found
		return global_position

func estimate_intercept_time(torpedo: Node2D, pdc_pos: Vector2) -> float:
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo) / WorldSettings.meters_per_pixel
	var distance = pdc_pos.distance_to(torpedo_pos)
	var bullet_speed = bullet_velocity_mps / WorldSettings.meters_per_pixel
	
	var closing_speed = torpedo_vel.dot((pdc_pos - torpedo_pos).normalized())
	var net_approach_speed = bullet_speed + closing_speed
	
	if net_approach_speed <= 0:
		return 999.0
	
	return distance / net_approach_speed

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
	var mode_name = "AREA" if current_mode == EngagementMode.AREA_SATURATION else "DIRECT"
	var threat_status = "HIGH" if high_threat_mode else "NORMAL"
	var target_info = "None"
	
	if current_target:
		var pdc_pos = get_muzzle_world_position()
		var dist = pdc_pos.distance_to(current_target.global_position) * WorldSettings.meters_per_pixel
		target_info = "%.0fm" % dist
	
	return "PDC: %s | %s | %s | Target: %s | Kills: %d" % [state_name, mode_name, threat_status, target_info, torpedoes_destroyed]
