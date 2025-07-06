# Scripts/Entities/Weapons/PDCSystem.gd - FIXED VERSION - NO BACKWARDS FIRING
extends Node2D
class_name PDCSystem

# PDC Configuration
@export var bullet_velocity_mps: float = 800.0
@export var bullets_per_burst: int = 150
@export var burst_fire_rate: float = 60.0
@export var burst_cooldown: float = 0.05
@export var engagement_range_meters: float = 15000.0
@export var min_intercept_distance_meters: float = 5.0
@export var turret_rotation_speed: float = 45.0

# NEW: Field of view restrictions - PDCs can only fire forward
@export var max_firing_angle: float = 80.0  # Degrees from forward direction (160° total arc)
var ship_forward_direction: Vector2 = Vector2.UP  # Default ship forward direction

# Dual-mode engagement system
enum EngagementMode { AREA_SATURATION, DIRECT_TARGETING }
var current_mode: EngagementMode = EngagementMode.AREA_SATURATION
@export var saturation_range_meters: float = 3000.0
@export var saturation_fire_rate: float = 80.0
@export var direct_fire_rate: float = 100.0
@export var target_lock_duration: float = 1.5

# Firing state management
enum FiringState { IDLE, TRACKING, FIRING, COOLDOWN }
var current_state: FiringState = FiringState.IDLE

# Target management
var current_target: Node2D = null
var target_locked_at: float = 0.0
var burst_bullets_fired: int = 0
var cooldown_timer: float = 0.0
var fire_timer: float = 0.0
var game_time: float = 0.0

# Target persistence for rapid salvos
var target_switch_cooldown: float = 0.5
var last_target_switch: float = 0.0
var high_threat_mode: bool = false

# Turret rotation and positioning - FIXED
var current_rotation: float = 0.0
var target_rotation: float = 0.0
var default_rotation: float = 0.0  # PDC's default facing direction relative to ship

# References and positioning
var parent_ship: Node2D
var sensor_system: SensorSystem
var sprite: Sprite2D
var muzzle_point: Marker2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# Statistics
var total_shots_fired: int = 0
var torpedoes_destroyed: int = 0

# Area saturation variables
var saturation_spread: float = 0.05

func _ready():
	parent_ship = get_parent()
	sprite = get_node_or_null("Sprite2D")
	
	# Find muzzle point properly
	if sprite:
		muzzle_point = sprite.get_node_or_null("MuzzlePoint")
		# FIXED: Store the PDC's default rotation relative to ship (not absolute)
		default_rotation = 0.0  # PDCs should face forward by default
		current_rotation = default_rotation
	
	# Find sensor system on parent ship
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
	
	print("PDC turret initialized with forward-only firing")

func _physics_process(delta):
	if not sensor_system or not parent_ship:
		return
	
	# Update ship forward direction
	ship_forward_direction = Vector2.UP.rotated(parent_ship.rotation)
	
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
	
	for torpedo in torpedoes:
		if not is_valid_target(torpedo):
			continue
		
		# CRITICAL: Check if target is in firing arc BEFORE calculating priority
		if not is_target_in_firing_arc(torpedo):
			continue
		
		var priority = calculate_target_priority(torpedo, pdc_world_pos)
		
		# In high threat mode, boost priority of very close targets
		if high_threat_mode:
			var distance_m = pdc_world_pos.distance_to(torpedo.global_position) * WorldSettings.meters_per_pixel
			if distance_m < saturation_range_meters * 0.3:
				priority *= 2.0
		
		if priority > best_priority:
			best_priority = priority
			best_target = torpedo
	
	if best_target:
		# Check target switching cooldown unless in high threat mode
		if current_target != best_target:
			var time_since_switch = game_time - last_target_switch
			var min_switch_time = target_switch_cooldown
			
			if high_threat_mode:
				min_switch_time *= 0.3
			
			if time_since_switch >= min_switch_time or best_priority > calculate_target_priority(current_target, pdc_world_pos) * 2.0:
				current_target = best_target
				target_locked_at = game_time
				last_target_switch = game_time
				current_state = FiringState.TRACKING
				burst_bullets_fired = 0
				
				var distance_m = pdc_world_pos.distance_to(best_target.global_position) * WorldSettings.meters_per_pixel
				print("PDC acquired target at distance: %.0f meters" % distance_m)
		else:
			current_state = FiringState.TRACKING

func is_target_in_firing_arc(torpedo: Node2D) -> bool:
	if not torpedo or not parent_ship:
		return false
	
	var pdc_world_pos = get_muzzle_world_position()
	var to_torpedo = torpedo.global_position - pdc_world_pos
	
	# Calculate angle between ship forward direction and torpedo direction
	var angle_to_torpedo = ship_forward_direction.angle_to(to_torpedo.normalized())
	var angle_degrees = abs(rad_to_deg(angle_to_torpedo))
	
	# Only allow targeting within the forward firing arc
	return angle_degrees <= max_firing_angle

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
	
	# CRITICAL: Must be in firing arc
	if not is_target_in_firing_arc(torpedo):
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
	
	# Factor in how central the target is to our firing arc
	var to_torpedo_normalized = to_torpedo.normalized()
	var angle_factor = max(0.0, ship_forward_direction.dot(to_torpedo_normalized))
	
	# Factor in engagement mode
	var mode_factor = 1.0
	if current_mode == EngagementMode.DIRECT_TARGETING:
		if distance_meters < saturation_range_meters * 0.5:
			mode_factor = 3.0
	
	# Factor in intercept feasibility
	var intercept_factor = 1.0
	var intercept_time = estimate_intercept_time(torpedo, pdc_pos)
	if intercept_time > 8.0 or intercept_time < 0.05:
		intercept_factor = 0.1
	
	return distance_factor * 3.0 + speed_factor * 2.0 + angle_factor * 1.5 + mode_factor * 2.0 + intercept_factor * 1.0

func update_tracking():
	if not is_valid_target(current_target):
		print("PDC lost target - invalid")
		current_state = FiringState.IDLE
		current_target = null
		return
	
	# Calculate aim point based on current mode
	var desired_angle: float
	if current_mode == EngagementMode.AREA_SATURATION:
		desired_angle = calculate_area_saturation_angle(current_target)
	else:
		desired_angle = calculate_direct_intercept_angle(current_target)
	
	# CRITICAL: Ensure we're not trying to aim outside our firing arc
	desired_angle = clamp_angle_to_firing_arc(desired_angle)
	target_rotation = desired_angle
	
	# Check if we're aimed close enough to start firing
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	var max_angle_diff = 0.15 if current_mode == EngagementMode.DIRECT_TARGETING else 0.2
	
	if angle_diff < max_angle_diff:
		current_state = FiringState.FIRING
		fire_timer = 0.0

func clamp_angle_to_firing_arc(desired_angle: float) -> float:
	# Convert ship forward direction to an angle
	var ship_forward_angle = ship_forward_direction.angle()
	
	# Calculate the allowed angle range
	var max_angle_rad = deg_to_rad(max_firing_angle)
	var min_allowed = ship_forward_angle - max_angle_rad
	var max_allowed = ship_forward_angle + max_angle_rad
	
	# Normalize angles to handle wraparound
	var normalized_desired = fmod(desired_angle + PI, TAU) - PI
	var normalized_min = fmod(min_allowed + PI, TAU) - PI
	var normalized_max = fmod(max_allowed + PI, TAU) - PI
	
	# Clamp to allowed range
	if normalized_min <= normalized_max:
		return clamp(normalized_desired, normalized_min, normalized_max)
	else:
		# Handle wraparound case
		if normalized_desired >= normalized_min or normalized_desired <= normalized_max:
			return normalized_desired
		else:
			# Choose the closer boundary
			var dist_to_min = abs(angle_difference(normalized_desired, normalized_min))
			var dist_to_max = abs(angle_difference(normalized_desired, normalized_max))
			return normalized_min if dist_to_min < dist_to_max else normalized_max

func execute_firing_mode():
	if not is_valid_target(current_target):
		print("PDC target lost during burst")
		current_state = FiringState.COOLDOWN
		cooldown_timer = burst_cooldown
		current_target = null
		return
	
	# Update aim during burst
	var desired_angle: float
	if current_mode == EngagementMode.AREA_SATURATION:
		desired_angle = calculate_area_saturation_angle(current_target)
	else:
		desired_angle = calculate_direct_intercept_angle(current_target)
	
	# Ensure we stay within firing arc
	target_rotation = clamp_angle_to_firing_arc(desired_angle)
	
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
	
	# Position at muzzle point
	var muzzle_world_pos = get_muzzle_world_position()
	bullet.global_position = muzzle_world_pos
	
	# Calculate fire direction with appropriate spread
	var spread = 0.0
	if current_mode == EngagementMode.AREA_SATURATION:
		spread = randf_range(-saturation_spread, saturation_spread)
	else:
		spread = randf_range(-0.01, 0.01)
	
	var fire_direction = Vector2.from_angle(current_rotation + spread)
	
	# SAFETY CHECK: Ensure we're not firing backwards
	var dot_product = fire_direction.dot(ship_forward_direction)
	if dot_product < 0.1:  # Less than ~84 degrees from forward
		print("WARNING: Attempted to fire backwards, skipping shot")
		return
	
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
	var torpedo_pos = torpedo.global_position
	var torpedo_vel_mps = get_torpedo_velocity(torpedo)
	var pdc_world_pos = get_muzzle_world_position()
	
	if torpedo_vel_mps.length() < 5.0:
		return (torpedo_pos - pdc_world_pos).angle()
	
	# Simple lead calculation - aim where torpedo will be when bullet arrives
	var to_torpedo = torpedo_pos - pdc_world_pos
	var distance_meters = to_torpedo.length() * WorldSettings.meters_per_pixel
	var bullet_travel_time = distance_meters / bullet_velocity_mps
	
	# Predict torpedo position
	var torpedo_vel_pixels = torpedo_vel_mps / WorldSettings.meters_per_pixel
	var predicted_pos = torpedo_pos + torpedo_vel_pixels * bullet_travel_time
	
	var to_intercept = predicted_pos - pdc_world_pos
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
		
		# FIXED: Apply rotation relative to ship's orientation, not absolute
		# The turret sprite should rotate to show where it's aiming
		var relative_rotation = current_rotation - parent_ship.rotation
		sprite.rotation = relative_rotation

func get_muzzle_world_position() -> Vector2:
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
