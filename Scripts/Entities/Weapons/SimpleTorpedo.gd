# Scripts/Entities/Weapons/SimpleTorpedo.gd - PROPORTIONAL CONTROL WITH SMART THRUST
# Two-layer architecture: Trajectory generator + P-controller with intelligent thrust management
#
# Launch Sequence:
#   1. ALIGN: Pure rotation to face target (no thrust)
#   2. GENTLE: 1G thrust for 3 seconds
#   3. RAMP: Linear ramp from 1G to 100G over 10 seconds
#   4. CRUISE: Full 100G until 80% of journey
#   5. TERMINAL: Smart thrust reduction based on time and error
extends Area2D

# Static counter for sequential torpedo naming
static var torpedo_counter: int = 0

# Core parameters
@export var acceleration_cruise_g: float = 100.0  # Cruise phase acceleration
@export var terminal_phase_start: float = 0.80    # Start terminal at 80% of journey

# Launch sequence parameters
@export var launch_alignment_threshold_deg: float = 5.0  # Must be aligned within this before thrust
@export var launch_gentle_thrust_g: float = 1.0         # Initial gentle thrust
@export var launch_gentle_duration: float = 3.0          # How long to thrust gently
@export var launch_ramp_duration: float = 10.0           # How long to ramp to full thrust

# Proportional control parameters
@export var kp_heading_initial: float = 0.1      # Initial Kp for first 15 seconds
@export var kp_heading_final: float = 10.0        # Final Kp after ramping
@export var kp_initial_duration: float = 15.0    # How long to use initial Kp
@export var kp_ramp_duration: float = 15.0       # How long to ramp to final Kp
@export var max_turn_rate_deg: float = 9999.0      # Maximum rotation rate (deg/s)

# Terminal thrust parameters
@export var terminal_max_thrust_g: float = 10.0   # Max thrust at start of terminal
@export var terminal_min_thrust_g: float = 0.5    # Min thrust at impact
@export var terminal_time_window: float = 15.0    # Time window for thrust scaling
@export var terminal_thrust_curve: float = 2.0    # Exponential curve for time scaling
@export var error_thrust_weight: float = 0.8      # How much error affects thrust (0.2-1.0 range)
@export var error_threshold_deg: float = 5.0      # Error that gives full thrust authority

# Trajectory calculation
@export var intercept_iterations: int = 10        # Iterations for intercept calculation
@export var use_kinematic_prediction: bool = true # Use kinematics for time-to-impact

# Debug settings
@export var debug_output: bool = true
@export var debug_interval: float = 1.0

# Torpedo identity
var torpedo_id: String = ""
var faction: String = "friendly"
var target_node: Node2D = null

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var is_alive: bool = true
var marked_for_death: bool = false

# Trajectory state (Layer 1)
var intercept_point: Vector2 = Vector2.ZERO
var desired_heading: float = 0.0
var initial_target_distance: float = 0.0
var time_since_launch: float = 0.0

# Control state (Layer 2)
var current_heading_error: float = 0.0
var current_thrust_g: float = 0.0
var current_kp: float = 0.0  # Track current Kp for debug
var is_terminal_phase: bool = false

# Launch phase tracking
enum LaunchPhase {
	ALIGNING,      # Phase 0: Pure rotation, no thrust
	GENTLE_START,  # Phase 1: 1G for 3 seconds
	RAMPING,       # Phase 2: Ramp from 1G to 100G over 10 seconds
	CRUISE         # Phase 3: Full thrust cruise
}
var launch_phase: LaunchPhase = LaunchPhase.ALIGNING
var phase_start_time: float = 0.0  # When current phase started

# Tracking
var closest_approach_distance: float = INF
var closest_approach_time: float = 0.0

# Visual elements
var trajectory_line: Line2D = null

# Debug tracking
var last_debug_print: float = 0.0
var last_logged_progress: float = -1.0

func _ready():
	Engine.max_fps = 60
	
	# Generate sequential torpedo ID
	torpedo_counter += 1
	torpedo_id = "Torp_%d" % torpedo_counter
	
	print("[P-CONTROL] %s: Initialized" % torpedo_id)
	print("  - Launch: Align < %.1f°, then 1G for 3s, ramp to 100G over 10s" % launch_alignment_threshold_deg)
	print("  - Kp: %.2f for 15s, then ramp to %.1f over 15s" % [kp_heading_initial, kp_heading_final])
	print("  - Max turn rate: %.1f°/s" % max_turn_rate_deg)
	print("  - Terminal phase: >%.0f%%" % (terminal_phase_start * 100))
	print("  - Terminal thrust: %.1fG to %.1fG" % [terminal_max_thrust_g, terminal_min_thrust_g])
	print("  - Starting in ALIGNMENT phase (no thrust)")
	
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	var sprite = get_node_or_null("AnimatedSprite2D")
	if sprite:
		sprite.play()
	
	# Setup trajectory visualization
	setup_trajectory_line()
	
	# CRITICAL FIX: Set initial rotation toward target if we have one
	if target_node and is_instance_valid(target_node):
		var to_target = target_node.global_position - global_position
		# Set rotation so torpedo points at target
		# Since torpedo sprite points UP at rotation=0, and we want it to point at angle theta:
		# rotation = theta + PI/2
		rotation = to_target.angle() + PI/2
		print("  - Initial rotation set toward target: %.1f°" % rad_to_deg(rotation))

func setup_trajectory_line():
	trajectory_line = get_node_or_null("TrajectoryLine")
	if trajectory_line:
		trajectory_line.width = 2.0
		trajectory_line.default_color = Color.ORANGE
		trajectory_line.antialiased = true
		trajectory_line.z_index = 5
		trajectory_line.top_level = true

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Initialize on first frame
	if initial_target_distance <= 0 and target_node:
		initial_target_distance = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
		var range_km = initial_target_distance / 1000.0
		print("%s: Launch - range %.1f km" % [torpedo_id, range_km])
	
	time_since_launch += delta
	
	# Track closest approach
	update_closest_approach()
	
	# LAYER 1: Calculate trajectory (updates intercept point and desired heading)
	calculate_trajectory()
	
	# LAYER 2: Follow trajectory with proportional control
	apply_proportional_control(delta)
	
	# Apply smart thrust
	apply_smart_thrust(delta)
	
	# Update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Update visualization
	if trajectory_line:
		update_trajectory_visualization()
	
	# Debug output
	if debug_output:
		update_debug_output()
	
	check_world_bounds()

func calculate_trajectory():
	"""Layer 1: Simple trajectory generator - straight line to intercept"""
	if not target_node or not is_instance_valid(target_node):
		return
	
	# Get target state
	var target_velocity = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_velocity = target_node.get_velocity_mps()
	
	# Calculate intercept point
	var target_vel_pixels = target_velocity / WorldSettings.meters_per_pixel
	var target_pos = target_node.global_position
	
	# Simple iterative refinement
	intercept_point = target_pos
	for iteration in range(intercept_iterations):
		var to_intercept_vector = intercept_point - global_position
		var iter_distance_m = to_intercept_vector.length() * WorldSettings.meters_per_pixel
		
		# Calculate time with current intercept point
		var iter_time = calculate_time_to_impact(iter_distance_m)
		var new_intercept = target_pos + target_vel_pixels * iter_time
		
		# Check convergence
		if new_intercept.distance_to(intercept_point) < 1.0:
			break
		
		intercept_point = new_intercept
	
	# Calculate desired heading to final intercept
	var final_vector_to_intercept = intercept_point - global_position
	desired_heading = final_vector_to_intercept.angle()

func calculate_time_to_impact(distance_m: float) -> float:
	"""Calculate time to cover distance considering acceleration"""
	var current_speed = velocity_mps.length()
	
	# CRITICAL: When stationary or very slow, use kinematic prediction assuming we'll accelerate
	if current_speed < 100.0:  # Less than 100 m/s
		# Assume we'll accelerate at cruise acceleration
		var accel = acceleration_cruise_g * 9.81
		# Time to reach distance from near-standstill: t = sqrt(2d/a)
		return sqrt(2.0 * distance_m / accel)
	
	if use_kinematic_prediction and current_speed < 100000:  # Still accelerating
		# Use kinematics: d = v₀t + 0.5at²
		var accel = acceleration_cruise_g * 9.81
		
		# Will we reach max speed before target?
		var max_speed = 100000.0  # 100 km/s max
		var time_to_max = (max_speed - current_speed) / accel
		var dist_to_max = current_speed * time_to_max + 0.5 * accel * time_to_max * time_to_max
		
		if dist_to_max < distance_m:
			# Will reach max speed, then cruise
			var remaining_dist = distance_m - dist_to_max
			var cruise_time = remaining_dist / max_speed
			return time_to_max + cruise_time
		else:
			# Will hit target while still accelerating
			# Solve quadratic: 0.5at² + v₀t - d = 0
			var discriminant = current_speed * current_speed + 2 * accel * distance_m
			if discriminant < 0:
				return distance_m / max(current_speed, 1.0)
			
			return (-current_speed + sqrt(discriminant)) / accel
	else:
		# Constant velocity
		return distance_m / current_speed

func apply_proportional_control(delta):
	"""Layer 2: Proportional controller to follow trajectory"""
	
	# Get current velocity heading (where we're going)
	var current_heading: float
	if velocity_mps.length() > 10.0:  # Only use velocity angle if moving
		current_heading = velocity_mps.angle()
	else:
		current_heading = rotation - PI/2  # Back to original (was correct)
	
	# Calculate heading error
	current_heading_error = angle_difference(desired_heading, current_heading)
	
	# Dynamic Kp based on flight time
	if time_since_launch < kp_initial_duration:
		# First 15 seconds: Use initial low Kp
		current_kp = kp_heading_initial
	elif time_since_launch < kp_initial_duration + kp_ramp_duration:
		# Next 15 seconds: Ramp from initial to final Kp
		var ramp_progress = (time_since_launch - kp_initial_duration) / kp_ramp_duration
		current_kp = lerp(kp_heading_initial, kp_heading_final, ramp_progress)
	else:
		# After 30 seconds: Use final Kp
		current_kp = kp_heading_final
	
	# Proportional control
	var commanded_turn_rate = current_kp * current_heading_error
	
	# Limit turn rate
	var max_turn_rate_rad = deg_to_rad(max_turn_rate_deg)
	commanded_turn_rate = clamp(commanded_turn_rate, -max_turn_rate_rad, max_turn_rate_rad)
	
	# Apply rotation
	rotation += commanded_turn_rate * delta

func apply_smart_thrust(delta):
	"""Smart thrust management with launch sequence and terminal phase scaling"""
	
	# Calculate progress and phase
	var current_distance = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	var progress = 1.0 - (current_distance / initial_target_distance)
	progress = clamp(progress, 0.0, 1.0)
	
	# Calculate alignment factor (don't thrust sideways)
	var body_angle = rotation - PI/2  # Back to original
	var velocity_angle = velocity_mps.angle() if velocity_mps.length() > 10.0 else body_angle
	var alignment_error = angle_difference(velocity_angle, body_angle)
	var alignment_factor = max(0, cos(alignment_error))
	
	# LAUNCH SEQUENCE MANAGEMENT
	if launch_phase == LaunchPhase.ALIGNING:
		# Phase 0: Pure rotation, no thrust until aligned
		var error_deg = rad_to_deg(current_heading_error)
		
		# Handle angle wrapping - if error is close to ±180°, we might actually be aligned
		if abs(error_deg) > 175.0:
			# We're likely experiencing angle wrapping - check the opposite angle
			if error_deg > 0:
				error_deg = error_deg - 360.0
			else:
				error_deg = error_deg + 360.0
		
		if abs(error_deg) < launch_alignment_threshold_deg:
			# Aligned! Move to gentle start
			launch_phase = LaunchPhase.GENTLE_START
			phase_start_time = time_since_launch
			print("%s: Aligned! Starting gentle thrust (1G)" % torpedo_id)
		else:
			# Still aligning, no thrust
			current_thrust_g = 0.0
			return  # Don't apply any thrust
	
	elif launch_phase == LaunchPhase.GENTLE_START:
		# Phase 1: Gentle 1G thrust for 3 seconds
		current_thrust_g = launch_gentle_thrust_g
		
		if time_since_launch - phase_start_time >= launch_gentle_duration:
			# Move to ramping phase
			launch_phase = LaunchPhase.RAMPING
			phase_start_time = time_since_launch
			print("%s: Starting thrust ramp (1G -> 100G over 10s)" % torpedo_id)
	
	elif launch_phase == LaunchPhase.RAMPING:
		# Phase 2: Ramp from 1G to 100G over 10 seconds
		var ramp_progress = (time_since_launch - phase_start_time) / launch_ramp_duration
		ramp_progress = clamp(ramp_progress, 0.0, 1.0)
		
		# Linear interpolation from 1G to 100G
		current_thrust_g = lerp(launch_gentle_thrust_g, acceleration_cruise_g, ramp_progress)
		
		if ramp_progress >= 1.0:
			# Ramping complete, enter cruise
			launch_phase = LaunchPhase.CRUISE
			print("%s: Full thrust achieved! Entering cruise phase" % torpedo_id)
	
	else:  # LaunchPhase.CRUISE
		# Check if in terminal phase
		var was_terminal = is_terminal_phase
		is_terminal_phase = progress > terminal_phase_start
		
		if is_terminal_phase and not was_terminal:
			print("%s: TERMINAL PHASE at %.1f km/s" % [torpedo_id, velocity_mps.length() / 1000.0])
		
		if is_terminal_phase:
			# Terminal phase: Smart thrust scaling
			var time_to_impact = current_distance / max(velocity_mps.length(), 1.0)
			
			# Time-based scaling
			var time_factor = clamp(time_to_impact / terminal_time_window, 0.0, 1.0)
			var time_based_thrust = lerp(terminal_min_thrust_g, terminal_max_thrust_g, pow(time_factor, terminal_thrust_curve))
			
			# Error-based multiplier (0.2 to 1.0 range)
			var error_mult = 0.2 + error_thrust_weight * clamp(abs(rad_to_deg(current_heading_error)) / error_threshold_deg, 0.0, 1.0)
			
			# Combine factors
			current_thrust_g = time_based_thrust * error_mult
		else:
			# Normal cruise: Full thrust
			current_thrust_g = acceleration_cruise_g
	
	# Apply thrust with alignment factor
	var final_thrust = current_thrust_g * 9.81 * alignment_factor
	var thrust_direction = Vector2.from_angle(rotation - PI/2)  # Back to original
	velocity_mps += thrust_direction * final_thrust * delta

func angle_difference(to_angle: float, from_angle: float) -> float:
	"""Calculate shortest angular distance between two angles"""
	var diff = fmod(to_angle - from_angle, TAU)
	if diff > PI:
		diff -= TAU
	elif diff < -PI:
		diff += TAU
	return diff

func update_trajectory_visualization():
	if not trajectory_line:
		return
	
	trajectory_line.clear_points()
	
	# Color based on phase
	if is_terminal_phase:
		trajectory_line.default_color = Color.CYAN
	else:
		trajectory_line.default_color = Color.ORANGE
	
	# Draw line to intercept
	trajectory_line.add_point(global_position)
	trajectory_line.add_point(intercept_point)

func update_debug_output():
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_print < debug_interval:
		return
	last_debug_print = current_time
	
	if not target_node:
		return
	
	var speed_kms = velocity_mps.length() / 1000.0
	var range_km = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel / 1000.0
	
	# Calculate body-velocity alignment
	var body_angle = rotation - PI/2  # Back to original
	var velocity_angle = velocity_mps.angle() if velocity_mps.length() > 10.0 else body_angle
	var alignment_error = angle_difference(velocity_angle, body_angle)
	var alignment_deg = rad_to_deg(alignment_error)
	
	# Phase info
	var current_distance = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	var progress = 1.0 - (current_distance / initial_target_distance)
	
	# Determine phase string
	var phase_str: String
	if launch_phase == LaunchPhase.ALIGNING:
		phase_str = "ALGN"
	elif launch_phase == LaunchPhase.GENTLE_START:
		phase_str = "GNTL"
	elif launch_phase == LaunchPhase.RAMPING:
		phase_str = "RAMP"
	elif is_terminal_phase:
		phase_str = "TERM"
	else:
		phase_str = "CRSE"
	
	# Log phase changes
	if abs(progress - last_logged_progress) > 0.1:
		var phase_name = ""
		if launch_phase == LaunchPhase.ALIGNING:
			phase_name = "Aligning"
		elif launch_phase == LaunchPhase.GENTLE_START:
			phase_name = "Gentle Start"
		elif launch_phase == LaunchPhase.RAMPING:
			phase_name = "Ramping"
		elif progress < terminal_phase_start:
			phase_name = "Cruise"
		else:
			phase_name = "Terminal"
		print("%s: %s phase (%.0f%%)" % [torpedo_id, phase_name, progress * 100])
		last_logged_progress = progress
	
	# FIXED: Actually include Kp in the output!
	print("%s: %.1f km/s | %.1f km | Err: %.1f° | Align: %.1f° | Thrust: %.1fG | Kp: %.2f | %s" % 
		[torpedo_id, speed_kms, range_km, rad_to_deg(current_heading_error), alignment_deg, current_thrust_g, current_kp, phase_str])

func update_closest_approach():
	if not target_node:
		return
	
	var current_distance = global_position.distance_to(target_node.global_position)
	var current_distance_meters = current_distance * WorldSettings.meters_per_pixel
	
	if current_distance_meters < closest_approach_distance:
		closest_approach_distance = current_distance_meters
		closest_approach_time = time_since_launch

func check_world_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")

func _on_area_entered(area: Area2D):
	if marked_for_death or not is_alive:
		return
	
	if area.is_in_group("ships"):
		if area.get("faction") == faction:
			return
		
		# Calculate final alignment
		var velocity_angle = velocity_mps.angle()
		var body_angle = rotation - PI/2  # Back to original
		var alignment_diff = rad_to_deg(angle_difference(velocity_angle, body_angle))
		
		print("SUCCESS [%s]: HIT %s!" % [torpedo_id, area.name])
		print("  - Impact: %.1fs at %.1f km" % [time_since_launch, closest_approach_distance / 1000.0])
		print("  - Speed: %.1f km/s" % (velocity_mps.length() / 1000.0))
		print("  - Alignment: %.1f°" % alignment_diff)
		
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("torpedo_impact")
		
		mark_for_destruction("target_impact")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	if reason == "out_of_bounds" and closest_approach_distance < INF:
		print("MISS [%s]: %s | Closest: %.1f km at %.1fs" % 
			[torpedo_id, reason, closest_approach_distance / 1000.0, closest_approach_time])
	elif reason == "target_impact":
		print("HIT [%s]: Target destroyed" % torpedo_id)
	else:
		print("LOST [%s]: %s" % [torpedo_id, reason])
	
	if trajectory_line:
		trajectory_line.visible = false
	
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	queue_free()

# Public interface
func set_target(target: Node2D):
	target_node = target
	if target_node:
		print("  - Target: %s" % target_node.name)

func set_launcher(launcher_ship: Node2D):
	if "faction" in launcher_ship:
		faction = launcher_ship.faction

func get_velocity_mps() -> Vector2:
	return velocity_mps

# Compatibility stubs
func set_launch_side(_side: int):
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	pass
