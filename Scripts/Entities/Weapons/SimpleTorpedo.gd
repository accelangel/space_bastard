# Scripts/Entities/Weapons/SimpleTorpedo.gd - ENHANCED DEBUG VERSION
# Full PID control with proper phase separation and intercept delay
extends Area2D

# Static counter for sequential torpedo naming
static var torpedo_counter: int = 0

# ============================================================================
# EXPORTED PARAMETERS
# ============================================================================

@export_group("Core Physics")
@export var launch_thrust_g: float = 150.0  # Main thrust (no ramping)
@export var terminal_phase_start: float = 0.97
@export var close_range_distance_m: float = 500.0

@export_group("Launch Sequence")
@export var launch_alignment_threshold_deg: float = 5.0  # Must align within this before thrust
@export var intercept_delay: float = 0.5  # Seconds after thrust before using intercept calculations

@export_group("PID Gains")
@export var kp_gain: float = 2.0  # Proportional gain (fixed, no ramping)
@export var ki_gain: float = 0.0  # Integral gain (usually 0 for torpedoes)
@export var kd_gain: float = 0.4  # Derivative gain (Kp/5 ratio)
# Note: Try Kp=1.0, Kd=0.3 if oscillating, or Kp=3.0, Kd=1.0 for more aggressive

@export_group("PID Limits")
@export var max_turn_rate_deg: float = 999999.0
@export var integral_limit_deg: float = 30.0
@export var integral_decay_rate: float = 0.95
@export var heading_filter_alpha: float = 0.8

@export_group("Terminal Phase")
@export var terminal_max_thrust_g: float = 10.0
@export var terminal_min_thrust_g: float = 2.0
@export var terminal_time_window: float = 15.0
@export var terminal_thrust_curve: float = 2.0

@export_group("Debug Settings")
@export var debug_enabled: bool = true
@export var debug_hz: float = 1.0  # Debug frequency in Hz

# ============================================================================
# INTERNAL STATE
# ============================================================================

# Identity
var torpedo_id: String = ""
var faction: String = "friendly"
var target_node: Node2D = null

# Physics
var velocity_mps: Vector2 = Vector2.ZERO
var is_alive: bool = true
var marked_for_death: bool = false

# Trajectory Layer
var intercept_point: Vector2 = Vector2.ZERO
var desired_heading: float = 0.0
var filtered_heading: float = 0.0

# PID Control Layer
var heading_error: float = 0.0
var prev_heading_error: float = 0.0
var integral_error: float = 0.0
var p_term: float = 0.0
var i_term: float = 0.0
var d_term: float = 0.0
var current_kp: float = 0.0
var current_ki: float = 0.0
var current_kd: float = 0.0

# Flight State
var time_since_launch: float = 0.0
var time_thrust_started: float = -1.0  # Track when thrust actually began
var initial_distance_m: float = 0.0
var is_terminal: bool = false
var is_close_range: bool = false
var current_thrust_g: float = 0.0

# Launch Phase
enum LaunchPhase {
	ALIGNING,
	CRUISE
}
var launch_phase: LaunchPhase = LaunchPhase.ALIGNING

# Rotation Tracking
var actual_rotation_rate: float = 0.0
var prev_rotation: float = 0.0

# Debug Management
var last_debug_time: float = 0.0
var debug_interval: float = 1.0

# Flight Statistics (for end report)
var max_rotation_rate: float = 0.0
var max_speed_achieved: float = 0.0
var total_heading_error: float = 0.0
var heading_error_samples: int = 0
var closest_approach: float = INF

# Visual
var trajectory_line: Line2D = null

# ============================================================================
# INITIALIZATION
# ============================================================================

func _ready():
	Engine.max_fps = 60
	
	# Generate ID
	torpedo_counter += 1
	torpedo_id = "Torp_%d" % torpedo_counter
	
	# Calculate debug interval from Hz
	debug_interval = 1.0 / debug_hz if debug_hz > 0 else 1.0
	
	# Initial debug output
	print("\n[%s] INITIALIZED" % torpedo_id)
	if debug_enabled:
		print("  Config: %.0fG thrust | Kp=%.1f Kd=%.2f | %.0f°/s max turn" % 
			[launch_thrust_g, kp_gain, kd_gain, max_turn_rate_deg])
		var test_vec = Vector2.UP.rotated(0.1)
		print("  Rotation: Positive = %s" % ["CCW" if test_vec.x > 0 else "CW"])
	
	# Setup groups and metadata
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Connect signals
	area_entered.connect(_on_area_entered)
	
	# Start animation
	var sprite = get_node_or_null("AnimatedSprite2D")
	if sprite:
		sprite.play()
	
	# Setup visualization
	setup_trajectory_line()
	
	# Initial targeting
	if target_node and is_instance_valid(target_node):
		var to_target = target_node.global_position - global_position
		rotation = to_target.angle() + PI/2
		prev_rotation = rotation
		filtered_heading = to_target.angle()
		
		# Initialize prev_heading_error to prevent D-term spike
		var initial_body_angle = rotation - PI/2
		heading_error = angle_wrap(to_target.angle() - initial_body_angle)
		prev_heading_error = heading_error
		
		if debug_enabled:
			print("  Initial aim: %.1f° (error: %.1f°)" % [rad_to_deg(to_target.angle()), rad_to_deg(heading_error)])

func setup_trajectory_line():
	trajectory_line = get_node_or_null("TrajectoryLine")
	if trajectory_line:
		trajectory_line.width = 2.0
		trajectory_line.default_color = Color.ORANGE
		trajectory_line.antialiased = true
		trajectory_line.z_index = 5
		trajectory_line.top_level = true

# ============================================================================
# MAIN UPDATE LOOP
# ============================================================================

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	if not target_node or not is_instance_valid(target_node):
		mark_for_destruction("no_target")
		return
	
	# Initialize launch distance
	if initial_distance_m <= 0:
		initial_distance_m = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
		print("[%s] Launch | Range: %.1fkm" % [torpedo_id, initial_distance_m / 1000.0])
	
	# Update time
	time_since_launch += delta
	
	# Calculate state
	var distance_m = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	var progress = 1.0 - (distance_m / initial_distance_m)
	is_close_range = distance_m < close_range_distance_m
	is_terminal = progress > terminal_phase_start or is_close_range
	
	# Check for phase transitions
	check_phase_transitions(progress, distance_m)
	
	# Track statistics
	closest_approach = min(closest_approach, distance_m)
	max_speed_achieved = max(max_speed_achieved, velocity_mps.length())
	
	# Track rotation rate
	actual_rotation_rate = angle_wrap(rotation - prev_rotation) / delta
	prev_rotation = rotation
	max_rotation_rate = max(max_rotation_rate, abs(actual_rotation_rate))
	
	# Trajectory calculation with delay
	if launch_phase == LaunchPhase.CRUISE:
		# Check if enough time has passed since thrust started
		var time_since_thrust = time_since_launch - time_thrust_started
		if time_since_thrust > intercept_delay:
			# Use full intercept calculations
			calculate_intercept()
		else:
			# Still in delay period - use simple targeting
			calculate_alignment_target()
	else:
		# During ALIGNING, just aim directly at target
		calculate_alignment_target()
	
	apply_pid_control(delta)
	apply_thrust(delta)
	
	# Track heading error statistics
	if launch_phase == LaunchPhase.CRUISE:
		total_heading_error += abs(heading_error)
		heading_error_samples += 1
	
	# Update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Visualization
	update_trajectory_visual()
	
	# Debug output (throttled)
	output_debug(distance_m, progress)
	
	# Bounds check
	check_bounds()

# ============================================================================
# PHASE TRANSITION TRACKING
# ============================================================================

func check_phase_transitions(progress: float, distance_m: float):
	"""Log phase transitions for debugging"""
	
	# Track terminal phase entry
	if not is_terminal and progress > terminal_phase_start:
		print("\n[%s] >>> ENTERING TERMINAL PHASE at %.1f%% progress, %.1fkm range <<<" % 
			[torpedo_id, progress * 100, distance_m / 1000.0])
		print("  Current heading error: %.1f°" % rad_to_deg(heading_error))
		print("  Current speed: %.1f km/s" % (velocity_mps.length() / 1000.0))
		print("  PID gains transitioning: Kp=%.2f->%.2f, Kd=%.2f->%.2f" % 
			[kp_gain, kp_gain * 0.5, kd_gain, kd_gain * 0.5])
	
	# Track close range entry
	if not is_close_range and distance_m < close_range_distance_m:
		print("\n[%s] >>> ENTERING CLOSE RANGE at %.1fkm <<<" % 
			[torpedo_id, distance_m / 1000.0])
		print("  Current heading error: %.1f°" % rad_to_deg(heading_error))
		print("  Reducing gains by 50%%")

# ============================================================================
# LAYER 1: TRAJECTORY CALCULATION
# ============================================================================

func calculate_alignment_target():
	"""During alignment phase and early cruise, just aim at the target's current position"""
	if not target_node:
		return
	
	# Simple direct aim - no intercept calculations
	var target_pos = target_node.global_position
	desired_heading = (target_pos - global_position).angle()
	
	# No filtering during alignment - we want direct aim
	filtered_heading = desired_heading
	
	# Intercept point is just the target position during alignment
	intercept_point = target_pos

func calculate_intercept():
	"""During cruise phase (after delay), calculate proper intercept point"""
	if not target_node:
		return
	
	var target_pos = target_node.global_position
	var target_vel = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_vel = target_node.get_velocity_mps()
	
	if is_close_range:
		intercept_point = target_pos
		desired_heading = (target_pos - global_position).angle()
	else:
		var target_vel_pixels = target_vel / WorldSettings.meters_per_pixel
		intercept_point = target_pos
		
		for i in range(10):
			var to_intercept = intercept_point - global_position
			var dist_m = to_intercept.length() * WorldSettings.meters_per_pixel
			var time_to_impact = calculate_time_to_impact(dist_m)
			var new_intercept = target_pos + target_vel_pixels * time_to_impact
			
			if new_intercept.distance_to(intercept_point) < 1.0:
				break
			intercept_point = new_intercept
		
		desired_heading = (intercept_point - global_position).angle()
	
	var alpha = heading_filter_alpha if not is_close_range else 0.9
	filtered_heading = lerp_angle(filtered_heading, desired_heading, alpha)

func calculate_time_to_impact(distance_m: float) -> float:
	var speed = velocity_mps.length()
	
	if is_close_range or speed < 100:
		return distance_m / max(speed, 100.0)
	
	var accel = launch_thrust_g * 9.81
	if speed < 100000:
		var discriminant = speed * speed + 2 * accel * distance_m
		if discriminant > 0:
			return (-speed + sqrt(discriminant)) / accel
	
	return distance_m / speed

# ============================================================================
# LAYER 2: PID CONTROL
# ============================================================================

func apply_pid_control(delta):
	var current_heading: float
	if velocity_mps.length() > 50:
		current_heading = velocity_mps.angle()
	else:
		current_heading = rotation - PI/2
	
	heading_error = angle_wrap(filtered_heading - current_heading)
	
	update_gains()
	
	# P term
	p_term = current_kp * heading_error
	
	# I term
	integral_error += heading_error * delta
	integral_error *= pow(integral_decay_rate, delta)
	var integral_limit_rad = deg_to_rad(integral_limit_deg)
	integral_error = clamp(integral_error, -integral_limit_rad, integral_limit_rad)
	i_term = current_ki * integral_error
	
	# D term - WITH DIAGNOSTIC TRACKING
	var error_rate = angle_wrap(heading_error - prev_heading_error) / delta
	
	# Store the raw calculation for debugging
	if has_meta("d_term_raw"):
		set_meta("d_term_raw", current_kd * error_rate)
	else:
		set_meta("d_term_raw", 0.0)
	
	# Apply the negative sign (THIS MIGHT BE THE BUG!)
	d_term = -current_kd * error_rate
	
	# Store actual delta for debug output
	set_meta("last_delta", delta)
	
	prev_heading_error = heading_error
	
	# Combined control
	var commanded_rate = p_term + i_term + d_term
	
	# Apply limits
	var max_rate_rad = deg_to_rad(max_turn_rate_deg)
	commanded_rate = clamp(commanded_rate, -max_rate_rad, max_rate_rad)
	
	# Apply rotation
	rotation += commanded_rate * delta

func update_gains():
	# NO RAMPING - use fixed gains
	current_kp = kp_gain
	current_kd = kd_gain
	current_ki = ki_gain
	
	# Reduce gains in close range
	if is_close_range:
		current_kp *= 0.5
		current_kd *= 0.5
		current_ki *= 0.5

# ============================================================================
# LAYER 3: THRUST MANAGEMENT
# ============================================================================

func apply_thrust(delta):
	var body_angle = rotation - PI/2
	var vel_angle = velocity_mps.angle() if velocity_mps.length() > 10 else body_angle
	var alignment = max(0, cos(angle_wrap(vel_angle - body_angle)))
	
	if launch_phase == LaunchPhase.ALIGNING:
		if abs(rad_to_deg(heading_error)) < launch_alignment_threshold_deg:
			launch_phase = LaunchPhase.CRUISE
			time_thrust_started = time_since_launch  # Record when thrust actually starts
			print("[%s] Thrust ON" % torpedo_id)
		else:
			current_thrust_g = 0.0
			return
	
	# CRUISE - apply thrust based on phase
	if is_terminal:
		var dist_m = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
		var time_to_impact = dist_m / max(velocity_mps.length(), 1.0)
		var time_factor = clamp(time_to_impact / terminal_time_window, 0, 1)
		current_thrust_g = lerp(terminal_min_thrust_g, terminal_max_thrust_g, pow(time_factor, terminal_thrust_curve))
	else:
		current_thrust_g = launch_thrust_g
	
	var thrust = current_thrust_g * 9.81 * alignment
	var thrust_dir = Vector2.from_angle(rotation - PI/2)
	velocity_mps += thrust_dir * thrust * delta

# ============================================================================
# ENHANCED DEBUG OUTPUT
# ============================================================================

func output_debug(distance_m: float, progress: float):
	if not debug_enabled:
		return
	
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# ENHANCED: Dynamic debug frequency based on flight progress
	var dynamic_interval: float = debug_interval
	
	# Increase frequency at critical phases
	if progress >= 0.95:  # From 95% onwards
		dynamic_interval = 0.01  # 100 Hz for detailed terminal phase analysis
	elif progress >= 0.90:  # Approaching terminal
		dynamic_interval = 0.2  # 5 Hz
	elif is_close_range:  # Close range override
		dynamic_interval = 0.01  # 100 Hz when very close
	
	# Check if enough time has passed based on dynamic interval
	if current_time - last_debug_time < dynamic_interval:
		return
	last_debug_time = current_time
	
	# Calculate additional critical data
	var body_angle = rotation - PI/2
	var velocity_angle = velocity_mps.angle() if velocity_mps.length() > 10 else body_angle
	var body_vel_alignment = rad_to_deg(angle_wrap(velocity_angle - body_angle))
	
	var _heading_lag = rad_to_deg(angle_wrap(desired_heading - filtered_heading))
	
	var time_to_impact = distance_m / max(velocity_mps.length(), 1.0)
	
	# Calculate intercept stability (how much intercept point moved)
	var _intercept_delta = 0.0
	if has_meta("prev_intercept"):
		var prev_intercept = get_meta("prev_intercept")
		_intercept_delta = intercept_point.distance_to(prev_intercept) * WorldSettings.meters_per_pixel
	set_meta("prev_intercept", intercept_point)
	
	# Commanded rotation from PID
	var commanded_rot = rad_to_deg(p_term + i_term + d_term)
	
	# Target velocity (if moving)
	var _target_speed = 0.0
	if target_node and target_node.has_method("get_velocity_mps"):
		_target_speed = target_node.get_velocity_mps().length()
	
	# D-TERM DIAGNOSTIC DATA
	var actual_delta = get_meta("last_delta", 0.01667)  # Get actual delta from PID control
	var error_delta = heading_error - prev_heading_error  # Raw error change
	var error_rate = angle_wrap(error_delta) / actual_delta  # Use ACTUAL delta, not assumed
	var d_term_raw = current_kd * error_rate  # Before sign flip
	var _d_term_final = -d_term_raw  # After sign flip (what we use)
	
	# Check if D-term opposes P-term (BAD!) or assists (GOOD!)
	var p_sign = sign(p_term)
	var d_sign = sign(d_term)
	var d_opposes_p = (p_sign != 0 and d_sign != 0 and p_sign != d_sign)
	
	var phase_str = ""
	match launch_phase:
		LaunchPhase.ALIGNING: phase_str = "AL"
		LaunchPhase.CRUISE: 
			var time_since_thrust = time_since_launch - time_thrust_started
			if time_since_thrust < intercept_delay and time_thrust_started >= 0:
				phase_str = "DL"  # Delay
			elif is_terminal: 
				phase_str = "TM"
			elif is_close_range: 
				phase_str = "CL"
			else: 
				phase_str = "CR"
	
	var speed_kms = velocity_mps.length() / 1000.0
	var range_km = distance_m / 1000.0
	
	# COMPRESSED FORMAT WITH MORE DATA
	if progress >= 0.95:
		# Ultra-detailed for terminal phase at 100 Hz WITH D-TERM DIAGNOSTICS
		print("[%d]%s|%.0fkm/s|%.1fkm|%.1f%%|TTI:%.1fs|Err:%.1f°(prev:%.1f°)|ErrRate:%.1f°/s|P:%.1f|D:%.1f(raw:%.1f)|%s|Cmd:%.1f/Act:%.1f°/s" % 
			[torpedo_counter, phase_str, speed_kms, range_km, progress * 100, time_to_impact,
			 rad_to_deg(heading_error), rad_to_deg(prev_heading_error), rad_to_deg(error_rate),
			 rad_to_deg(p_term), rad_to_deg(d_term), rad_to_deg(d_term_raw),
			 "OPPOSE!" if d_opposes_p else "assist",
			 commanded_rot, rad_to_deg(actual_rotation_rate)])
		
		# Extra diagnostic line for critical moments
		if abs(commanded_rot) > 5.0 or d_opposes_p:
			print("  >>> D-TERM DEBUG: errDelta=%.3f° rate=%.1f°/s Kd=%.2f raw=%.1f final=%.1f P+D=%.1f" %
				[rad_to_deg(error_delta), rad_to_deg(error_rate), current_kd, 
				 rad_to_deg(d_term_raw), rad_to_deg(d_term), commanded_rot])
	else:
		# Standard but compressed for cruise phase
		print("[%d]%s|%.0fkm/s|%.1fkm|%.1f%%|TTI:%.1fs|Err:%.1f°|BV:%.1f°|PID:%.1f/%.1f|Rot:%.1f°/s|T:%.0fG" % 
			[torpedo_counter, phase_str, speed_kms, range_km, progress * 100, time_to_impact,
			 rad_to_deg(heading_error), body_vel_alignment,
			 rad_to_deg(p_term), rad_to_deg(d_term),
			 rad_to_deg(actual_rotation_rate), current_thrust_g])

# ============================================================================
# UTILITIES
# ============================================================================

func angle_wrap(angle: float) -> float:
	var wrapped = fmod(angle, TAU)
	if wrapped > PI:
		wrapped -= TAU
	elif wrapped < -PI:
		wrapped += TAU
	return wrapped

func lerp_angle(from: float, to: float, weight: float) -> float:
	var diff = angle_wrap(to - from)
	return from + diff * weight

func update_trajectory_visual():
	if not trajectory_line:
		return
	
	trajectory_line.clear_points()
	
	# Don't show line until we're past the delay period
	if launch_phase == LaunchPhase.ALIGNING:
		return
	
	# Also hide during the delay period
	if launch_phase == LaunchPhase.CRUISE and time_thrust_started >= 0:
		var time_since_thrust = time_since_launch - time_thrust_started
		if time_since_thrust < intercept_delay:
			return  # Don't show line during delay period
	
	# Color by state
	if abs(actual_rotation_rate) > deg_to_rad(180):
		trajectory_line.default_color = Color.RED
	elif is_close_range:
		trajectory_line.default_color = Color.YELLOW
	elif is_terminal:
		trajectory_line.default_color = Color.CYAN
	else:
		trajectory_line.default_color = Color.ORANGE
	
	trajectory_line.add_point(global_position)
	trajectory_line.add_point(intercept_point)

func check_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")

# ============================================================================
# COLLISION & LIFECYCLE
# ============================================================================

func _on_area_entered(area: Area2D):
	if marked_for_death or not is_alive:
		return
	
	if area.is_in_group("ships") and area.get("faction") != faction:
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("torpedo_impact")
		mark_for_destruction("target_hit")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Comprehensive end-of-flight report
	print("\n========== [%s] END OF FLIGHT REPORT ==========" % torpedo_id)
	print("Result: %s" % reason.to_upper())
	print("Flight Time: %.1f seconds" % time_since_launch)
	
	# Distance and speed
	print("Final Speed: %.1f km/s (Max: %.1f km/s)" % [velocity_mps.length() / 1000.0, max_speed_achieved / 1000.0])
	print("Closest Approach: %.1f km" % (closest_approach / 1000.0))
	var final_range = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel if target_node and is_instance_valid(target_node) else INF
	print("Final Range: %.1f km" % (final_range / 1000.0))
	
	# Body-velocity alignment
	if velocity_mps.length() > 100:
		var body_angle = rotation - PI/2
		var velocity_angle = velocity_mps.angle()
		var alignment_error = rad_to_deg(angle_wrap(velocity_angle - body_angle))
		print("Body-Velocity Alignment Error: %.1f°" % alignment_error)
		if abs(alignment_error) > 5:
			print("  WARNING: Poor alignment - torpedo was thrusting off-axis")
	
	# Control performance
	if heading_error_samples > 0:
		var avg_heading_error = total_heading_error / heading_error_samples
		print("Average Heading Error: %.1f°" % rad_to_deg(avg_heading_error))
	print("Max Rotation Rate: %.1f°/s" % rad_to_deg(max_rotation_rate))
	
	# Final heading error
	print("Final Heading Error: %.1f°" % rad_to_deg(heading_error))
	
	# PID performance
	print("Final PID State: P=%.1f°/s, D=%.1f°/s" % [rad_to_deg(p_term), rad_to_deg(d_term)])
	
	# Success/failure analysis
	if reason == "target_hit":
		print("SUCCESS: Direct impact!")
	elif reason == "out_of_bounds":
		print("FAILURE: Left map boundaries")
		if abs(heading_error) > deg_to_rad(10):
			print("  Likely cause: Poor tracking (high heading error)")
	elif reason == "no_target":
		print("FAILURE: Lost target lock")
	
	print("==================================================\n")
	
	# Cleanup
	if trajectory_line:
		trajectory_line.visible = false
	
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	queue_free()

# ============================================================================
# PUBLIC INTERFACE
# ============================================================================

func set_target(target: Node2D):
	target_node = target

func set_launcher(launcher: Node2D):
	if "faction" in launcher:
		faction = launcher.faction

func get_velocity_mps() -> Vector2:
	return velocity_mps

# Compatibility stubs
func set_launch_side(_side: int):
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	pass
