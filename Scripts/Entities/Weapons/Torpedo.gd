# Scripts/Entities/Weapons/Torpedo.gd - Frame-rate independent version
extends Area2D
class_name Torpedo

# Identity baked into the node
@export var torpedo_id: String = ""
@export var birth_time: float = 0.0
@export var faction: String = "hostile"
@export var source_ship_id: String = ""

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var death_reason: String = ""

# Core properties
var target_node: Node2D  # Direct reference, validated each frame
var launcher_ship: Node2D

# PHYSICS STATE - REAL SINGLE-AXIS THRUST
var velocity_mps: Vector2 = Vector2.ZERO  # Current actual velocity in m/s
var orientation: float = 0.0  # Direction torpedo is pointing (radians)
var max_speed_mps: float = 2000.0  # Speed limit for testing (will remove later)
var max_acceleration: float = 490.5  # 50G in m/s²
var max_rotation_rate: float = deg_to_rad(1080.0)  # Can turn 360°/second

# NORMALIZED PID Controller - Works at any speed
# Default values - will be replaced by tuner
const DEFAULT_PID_VALUES = {
	"straight": {"kp": 1.5, "ki": 0.05, "kd": 0.3},  # Much lower for high-speed straight intercepts
	"multi_angle": {"kp": 3.0, "ki": 0.2, "kd": 1.0},  # Lower for multi-angle
	"simultaneous": {"kp": 3.0, "ki": 0.2, "kd": 1.0}  # Lower for simultaneous
}

# Current PID gains (can be updated by tuner)
var pid_gains: Dictionary = {}
var integral_error: Vector2 = Vector2.ZERO
var previous_error: Vector2 = Vector2.ZERO
var integral_decay: float = 0.95  # Prevent integral windup

# Flight plan configuration
var flight_plan_type: String = "straight"  # "straight", "multi_angle", "simultaneous"
var flight_plan_data: Dictionary = {}  # approach_side, impact_time, impact_angle, etc.

# Launch system
var launch_side: int = 1  # 1 = starboard, -1 = port
var engines_ignited: bool = false
var launch_start_time: float = 0.0
var engine_ignition_time: float = 0.0

# Launch parameters
var lateral_launch_velocity: float = 60.0  # m/s sideways
var lateral_launch_distance: float = 80.0  # meters
var engine_ignition_delay: float = 1.6  # seconds
var lateral_distance_traveled: float = 0.0

# Miss detection system
var miss_detection_timer: float = 0.0
var miss_detection_threshold: float = 2.0  # seconds
var max_lifetime: float = 30.0  # Maximum torpedo lifetime
var closest_approach_distance: float = INF
var has_passed_target: bool = false

# Performance reporting
var pid_tuner: Node = null

# Debug visualization
var debug_trail: PackedVector2Array = []
var max_trail_points: int = 100

# Frame-rate independent timers
var debug_timer: float = 0.0
var debug_interval: float = 1.0  # Print every second
var position_report_timer: float = 0.0
var position_report_interval: float = 0.167  # Report ~6 times per second

func _ready():
	# Generate unique ID if not provided
	if torpedo_id == "":
		torpedo_id = "torpedo_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	birth_time = Time.get_ticks_msec() / 1000.0
	launch_start_time = birth_time
	
	# Initialize PID gains from defaults
	pid_gains = DEFAULT_PID_VALUES.duplicate(true)
	
	# Find PID tuner if it exists
	if Engine.has_singleton("TunerSystem"):
		pid_tuner = Engine.get_singleton("TunerSystem")
	
	# Add to groups for identification
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	# Store all identity data as metadata for redundancy
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	set_meta("source_ship_id", source_ship_id)
	
	# Validate target
	if not is_valid_target(target_node):
		print("Torpedo %s: No valid target, self-destructing" % torpedo_id)
		mark_for_destruction("no_target")
		return
	
	# Initialize physics based on launcher
	if launcher_ship:
		# Inherit ship velocity
		if launcher_ship.has_method("get_velocity_mps"):
			velocity_mps = launcher_ship.get_velocity_mps()
		
		# Set initial orientation to ship forward
		var ship_forward = Vector2.UP.rotated(launcher_ship.rotation)
		orientation = ship_forward.angle()
		rotation = orientation
		
		# Add lateral launch velocity
		var side_direction = Vector2(-ship_forward.y, ship_forward.x) * launch_side
		velocity_mps += side_direction * lateral_launch_velocity
		
		if "entity_id" in launcher_ship:
			source_ship_id = launcher_ship.entity_id
	
	# Connect collision
	area_entered.connect(_on_area_entered)
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "torpedo")
	
	var _target_name = "none"
	if target_node:
		_target_name = target_node.name
	#print("Torpedo %s launched - Plan: %s, Target: %s" % [
		#torpedo_id, flight_plan_type, _target_name
	#])

func _physics_process(delta):
	# Validate we're still alive
	if marked_for_death or not is_alive:
		return
	
	# Validate target every frame
	if not is_valid_target(target_node):
		target_node = null
		mark_for_destruction("target_lost")
		return
	
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_launch = current_time - launch_start_time
	
	# Check lifetime limit
	if time_since_launch > max_lifetime:
		report_miss("max_lifetime")
		mark_for_destruction("max_lifetime")
		return
	
	# Track lateral distance during launch phase
	if not engines_ignited:
		var distance_this_frame = velocity_mps.length() * delta
		lateral_distance_traveled += distance_this_frame
		
		# Check if engines should ignite
		if should_ignite_engines(time_since_launch):
			ignite_engines()
			engine_ignition_time = current_time
	
	# Main physics update
	if engines_ignited and target_node:
		update_physics_with_normalized_pid(delta)
		check_miss_conditions(delta)
	
	# Update position (convert to pixels)
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Update visual rotation to match orientation
	rotation = orientation
	
	# Check bounds
	check_out_of_bounds()
	
	# Update debug trail
	update_debug_trail()
	
	# Timer-based position reporting (frame-rate independent)
	position_report_timer += delta
	if position_report_timer >= position_report_interval:
		position_report_timer = 0.0
		get_tree().call_group("battle_observers", "on_entity_moved", self, global_position)

func update_physics_with_normalized_pid(delta: float):
	"""Main physics update using normalized PID control"""
	
	# Get desired velocity from flight plan
	var desired_velocity = get_desired_velocity_from_flight_plan()
	
	# NORMALIZED PID: Divide errors by max speed to make gains speed-independent
	var velocity_error = (desired_velocity - velocity_mps) / max_speed_mps
	
	# Get current PID gains for this trajectory type
	var gains = get_current_pid_gains()
	
	# Normalized PID control
	integral_error = (integral_error + velocity_error * delta) * integral_decay
	var derivative_error = (velocity_error - previous_error) / delta
	previous_error = velocity_error
	
	# PID output in normalized space
	var normalized_pid_output = (
		velocity_error * gains.kp +
		integral_error * gains.ki +
		derivative_error * gains.kd
	)
	
	# Convert back to world space
	var pid_output = normalized_pid_output * max_speed_mps
	
	# Desired orientation is in the direction of PID output
	var desired_orientation = pid_output.angle() if pid_output.length() > 0.1 else orientation
	
	# Apply rotation constraints
	var rotation_diff = angle_difference(orientation, desired_orientation)
	var max_rotation = max_rotation_rate * delta
	
	if abs(rotation_diff) > max_rotation:
		orientation += sign(rotation_diff) * max_rotation
	else:
		orientation = desired_orientation
	
	# Normalize orientation
	orientation = normalize_angle(orientation)
	
	# CRITICAL: Thrust ONLY in orientation direction
	var thrust_direction = Vector2.from_angle(orientation)
	var thrust_force = thrust_direction * max_acceleration
	
	# Update velocity
	velocity_mps += thrust_force * delta
	
	# Apply speed limit (remove this when going to full scale)
	if velocity_mps.length() > max_speed_mps:
		velocity_mps = velocity_mps.normalized() * max_speed_mps
	
	# Timer-based debug output (frame-rate independent)
	debug_timer += delta
	if debug_timer >= debug_interval:
		debug_timer = 0.0
		var _distance_to_target = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
		var _speed = velocity_mps.length()
		var velocity_angle = velocity_mps.angle() if velocity_mps.length() > 0.1 else 0.0
		var _orientation_error = rad_to_deg(abs(angle_difference(orientation, velocity_angle)))
		
		#print("Torpedo %s: Speed %.1f m/s, Distance %.1f m, Orient error: %.1f°, Plan: %s" % [
			#torpedo_id, _speed, _distance_to_target, _orientation_error, flight_plan_type
		#])

func get_current_pid_gains() -> Dictionary:
	# Check if tuner has updated gains
	if pid_tuner and pid_tuner.has_method("get_pid_gains"):
		var tuner_gains = pid_tuner.get_pid_gains(flight_plan_type)
		if tuner_gains.size() > 0:
			return tuner_gains
	
	# Otherwise use stored gains
	return pid_gains.get(flight_plan_type, DEFAULT_PID_VALUES[flight_plan_type])

func update_pid_gains(new_gains: Dictionary):
	"""Called by PID tuner to update gains"""
	pid_gains[flight_plan_type] = new_gains

func check_miss_conditions(delta: float):
	"""Check if torpedo has missed its target"""
	if not target_node:
		return
	
	# Calculate distance to target
	var to_target = target_node.global_position - global_position
	var distance = to_target.length() * WorldSettings.meters_per_pixel
	
	# Track closest approach
	if distance < closest_approach_distance:
		closest_approach_distance = distance
		has_passed_target = false
		miss_detection_timer = 0.0
	
	# Check if moving away from target
	var closing_velocity = velocity_mps.dot(to_target.normalized())
	
	if closing_velocity < 0 and distance > 50.0:  # Moving away and more than 50m away
		if not has_passed_target:
			has_passed_target = true
			#print("Torpedo %s: Passed target, distance %.1f m" % [torpedo_id, distance])
		
		miss_detection_timer += delta
		
		if miss_detection_timer >= miss_detection_threshold:
			report_miss("overshot")
			mark_for_destruction("missed_target")

func report_miss(reason: String):
	"""Report miss to PID tuner for analysis"""
	if pid_tuner and pid_tuner.has_method("report_torpedo_miss"):
		var miss_data = {
			"torpedo_id": torpedo_id,
			"flight_plan_type": flight_plan_type,
			"closest_approach": closest_approach_distance,
			"lifetime": (Time.get_ticks_msec() / 1000.0) - launch_start_time,
			"reason": reason
		}
		pid_tuner.report_torpedo_miss(miss_data)

func report_hit():
	"""Report successful hit to PID tuner"""
	if pid_tuner and pid_tuner.has_method("report_torpedo_hit"):
		var hit_data = {
			"torpedo_id": torpedo_id,
			"flight_plan_type": flight_plan_type,
			"time_to_impact": (Time.get_ticks_msec() / 1000.0) - launch_start_time
		}
		pid_tuner.report_torpedo_hit(hit_data)

func get_desired_velocity_from_flight_plan() -> Vector2:
	"""Get desired velocity based on current flight plan"""
	if not target_node:
		return velocity_mps  # Maintain current velocity if no target
	
	var target_pos = target_node.global_position
	var target_vel = get_target_velocity()
	
	match flight_plan_type:
		"straight":
			return TorpedoFlightPlans.calculate_straight_intercept(
				global_position, velocity_mps, target_pos, target_vel, max_speed_mps
			)
		
		"multi_angle":
			var approach_side = flight_plan_data.get("approach_side", launch_side)
			return TorpedoFlightPlans.calculate_multi_angle_intercept(
				global_position, velocity_mps, target_pos, target_vel, 
				max_speed_mps, approach_side
			)
		
		"simultaneous":
			var current_time = Time.get_ticks_msec() / 1000.0
			var launch_time = flight_plan_data.get("launch_time", launch_start_time)
			var total_impact_time = flight_plan_data.get("impact_time", 10.0)
			var time_to_impact = total_impact_time - (current_time - launch_time)
			var impact_angle = flight_plan_data.get("impact_angle", 0.0)
			
			return TorpedoFlightPlans.calculate_simultaneous_impact_intercept(
				global_position, velocity_mps, target_pos, target_vel,
				max_speed_mps, time_to_impact, impact_angle
			)
		
		_:
			# Default to straight intercept
			return TorpedoFlightPlans.calculate_straight_intercept(
				global_position, velocity_mps, target_pos, target_vel, max_speed_mps
			)

func should_ignite_engines(time_since_launch: float) -> bool:
	var distance_criteria_met = lateral_distance_traveled >= lateral_launch_distance
	var time_criteria_met = time_since_launch >= engine_ignition_delay
	return distance_criteria_met or time_criteria_met

func ignite_engines():
	engines_ignited = true
	#print("Torpedo %s: Engines ignited! Flight plan: %s" % [torpedo_id, flight_plan_type])

func get_target_velocity() -> Vector2:
	if not target_node:
		return Vector2.ZERO
	
	if target_node.has_method("get_velocity_mps"):
		return target_node.get_velocity_mps()
	elif "velocity_mps" in target_node:
		return target_node.velocity_mps
	
	return Vector2.ZERO

func is_valid_target(target: Node2D) -> bool:
	if not target:
		return false
	if not is_instance_valid(target):
		return false
	if not target.is_inside_tree():
		return false
	if target.has_method("is_alive") and not target.is_alive:
		return false
	if target.get("marked_for_death") and target.marked_for_death:
		return false
	return true

func check_out_of_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		#print("Torpedo %s went out of bounds at position %s" % [torpedo_id, global_position])
		report_miss("out_of_bounds")
		mark_for_destruction("out_of_bounds")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return  # Already dying
	
	marked_for_death = true
	is_alive = false
	death_reason = reason
	
	# Disable immediately
	set_physics_process(false)
	
	# FIXED: Use call_deferred to disable collision shape
	if has_node("CollisionShape2D"):
		call_deferred("_disable_collision")
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	# Safe cleanup
	queue_free()

# Add this new function to handle deferred collision disabling:
func _disable_collision():
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true

func _on_area_entered(area: Area2D):
	if marked_for_death:
		return
	
	# Collide with PDC bullets
	if area.is_in_group("bullets"):
		# Don't collide with same faction
		if area.get("faction") == faction:
			return
		
		# Store hit information on the bullet (it will handle the collision)
		area.set_meta("hit_target", torpedo_id)
		
		# Self destruct
		mark_for_destruction("bullet_impact")
		return
	
	# Collide with ships
	if area.is_in_group("ships"):
		# Don't collide with same faction (friendly fire protection)
		if area.get("faction") == faction:
			return
		
		#print("Torpedo %s hit ship %s" % [torpedo_id, area.get("entity_id")])
		report_hit()
		# Torpedo is destroyed, ship survives (testing phase)
		mark_for_destruction("ship_impact")

# Utility functions
func angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

func normalize_angle(angle: float) -> float:
	while angle > PI:
		angle -= TAU
	while angle < -PI:
		angle += TAU
	return angle

func update_debug_trail():
	debug_trail.append(global_position)
	if debug_trail.size() > max_trail_points:
		debug_trail.remove_at(0)

# Configuration methods called by launcher
func set_target(target: Node2D):
	target_node = target

func set_launcher(ship: Node2D):
	launcher_ship = ship
	if ship and "faction" in ship:
		faction = ship.faction

func set_launch_side(side: int):
	launch_side = side

func set_flight_plan(plan_type: String, plan_data: Dictionary = {}):
	flight_plan_type = plan_type
	flight_plan_data = plan_data

# For PDC targeting
func get_velocity_mps() -> Vector2:
	return velocity_mps

func get_current_position() -> Vector2:
	return global_position

func get_predicted_position(time_ahead: float) -> Vector2:
	# Simple linear prediction for now
	return global_position + (velocity_mps / WorldSettings.meters_per_pixel) * time_ahead

# Debug drawing
func _draw():
	if debug_trail.size() < 2:
		return
	
	# Draw trail
	for i in range(1, debug_trail.size()):
		var from = to_local(debug_trail[i-1])
		var to = to_local(debug_trail[i])
		var alpha = float(i) / float(debug_trail.size())
		draw_line(from, to, Color(1, 0.5, 0, alpha), 2.0)
