# Scripts/Entities/Weapons/TorpedoBase.gd
extends Area2D
class_name TorpedoBase

# Waypoint class with velocity profiles
class Waypoint extends RefCounted:
	var position: Vector2
	var velocity_target: float = 2000.0      # Desired speed at this waypoint in m/s
	var velocity_tolerance: float = 500.0    # How close to target velocity
	var maneuver_type: String = "cruise"     # "cruise", "flip", "burn", "curve", "terminal"
	var thrust_limit: float = 1.0            # 0.0-1.0, allows fine control per segment
	var max_acceleration: float = 490.5      # For validation
	
	func should_accept(torpedo_pos: Vector2, torpedo_vel: float, torpedo_velocity_vec: Vector2) -> bool:
		var pos_error = position.distance_to(torpedo_pos) * WorldSettings.meters_per_pixel
		var vel_error = abs(velocity_target - torpedo_vel)
		
		# Position acceptance
		if pos_error < 500.0:  # 500m acceptance radius
			return true
			
		# Also accept if we're close in velocity and moving toward waypointty
		if vel_error < velocity_tolerance and is_moving_toward_waypoint(torpedo_pos, position, torpedo_velocity_vec):
			return true
			
		return false
	
	func is_moving_toward_waypoint(torpedo_pos: Vector2, waypoint_pos: Vector2, torpedo_vel: Vector2) -> bool:
		# Check if velocity vector points toward waypoint
		var to_waypoint = waypoint_pos - torpedo_pos
		if to_waypoint.length() < 0.1:
			return true  # Already at waypoint
		
		var velocity_dot = torpedo_vel.normalized().dot(to_waypoint.normalized())
		return velocity_dot > 0.5  # Moving generally toward waypoint (within 60 degrees)
	

# Identity
@export var torpedo_id: String = ""
@export var faction: String = "hostile"

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var orientation: float = 0.0
var max_acceleration: float = 490.5  # 50G
var max_rotation_rate: float = deg_to_rad(1080.0)  # 3 rotations/second

# Waypoint system
var waypoints: Array = []  # Godot 4 doesn't support typed arrays with inner classes
var current_waypoint_index: int = 0

# Trail rendering
var trail_line: Line2D
var trail_quality: float = 0.0
var trail_quality_factors = {
	"alignment_error": 0.3,      # 30% weight
	"velocity_matching": 0.3,    # 30% weight  
	"control_smoothness": 0.2,   # 20% weight
	"path_accuracy": 0.2         # 20% weight
}

# Performance metrics
var alignment_score: float = 0.0
var velocity_score: float = 0.0
var smoothness_score: float = 0.0
var path_score: float = 0.0

# ProportionalNavigation component
var proportional_nav: ProportionalNavigation

# Target tracking
var target_node: Node2D

# State management
var is_alive: bool = true
var marked_for_death: bool = false

# Flight plan
var flight_plan_type: String = "straight"
var flight_plan_data: Dictionary = {}

func _ready():
	# Generate ID if not provided
	if torpedo_id == "":
		torpedo_id = "torpedo_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Add to groups
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	# Create ProportionalNavigation component
	proportional_nav = ProportionalNavigation.new()
	proportional_nav.name = "ProportionalNavigation"
	add_child(proportional_nav)
	
	# Create trail
	create_trail()
	
	# Connect collision
	area_entered.connect(_on_area_entered)

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# Update guidance if we have waypoints
	if waypoints.size() > 0 and current_waypoint_index < waypoints.size():
		var current_wp = waypoints[current_waypoint_index]
		var next_wp = waypoints[current_waypoint_index + 1] if current_waypoint_index + 1 < waypoints.size() else null
		
		# Get guidance from ProportionalNavigation
		var guidance = proportional_nav.calculate_guidance(
			global_position, velocity_mps, orientation,
			max_acceleration, max_rotation_rate,
			current_wp, next_wp
		)
		
		# Apply control
		apply_control(guidance, delta)
		
		# Check waypoint acceptance
		if current_wp.should_accept(global_position, velocity_mps.length()):
			current_waypoint_index += 1
	
	# Update position
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Update visual rotation
	rotation = orientation
	
	# Update quality metrics
	update_trail_quality()

func apply_control(control: Dictionary, delta: float):
	# Update orientation
	orientation += control.turn_rate * delta
	orientation = wrapf(orientation, -PI, PI)
	
	# Update velocity
	var thrust_direction = Vector2.from_angle(orientation)
	var acceleration = thrust_direction * control.thrust * max_acceleration
	velocity_mps += acceleration * delta

func apply_waypoint_update(new_waypoints: Array, protected_count: int):
	# Preserve current and next N waypoints
	var preserved = []
	for i in range(min(protected_count, waypoints.size() - current_waypoint_index)):
		preserved.append(waypoints[current_waypoint_index + i])
	
	# Clear old waypoints
	waypoints.clear()
	
	# Add preserved waypoints first
	waypoints.append_array(preserved)
	
	# Add new waypoints
	for wp in new_waypoints:
		waypoints.append(wp)

func create_trail():
	trail_line = Line2D.new()
	trail_line.name = "Trail"
	trail_line.width = 2.0
	trail_line.default_color = Color.GREEN
	trail_line.z_index = -1
	get_parent().add_child(trail_line)

func update_trail_quality():
	# Calculate each factor
	alignment_score = calculate_alignment_score()
	velocity_score = calculate_velocity_matching_score()
	smoothness_score = calculate_control_smoothness()
	path_score = calculate_path_accuracy()
	
	# Weighted average
	trail_quality = (
		alignment_score * trail_quality_factors.alignment_error +
		velocity_score * trail_quality_factors.velocity_matching +
		smoothness_score * trail_quality_factors.control_smoothness +
		path_score * trail_quality_factors.path_accuracy
	)
	
	# Update trail color
	update_trail_color()

func calculate_alignment_score() -> float:
	if velocity_mps.length() < 10.0:
		return 1.0
	
	var velocity_angle = velocity_mps.angle()
	var alignment_error = abs(angle_difference(orientation, velocity_angle))
	return 1.0 - (alignment_error / PI)

func calculate_velocity_matching_score() -> float:
	if waypoints.is_empty() or current_waypoint_index >= waypoints.size():
		return 1.0
		
	var current_speed = velocity_mps.length()
	var target_speed = waypoints[current_waypoint_index].velocity_target
	var error = abs(current_speed - target_speed) / max(target_speed, 100.0)
	return 1.0 - min(error, 1.0)

func calculate_control_smoothness() -> float:
	# Placeholder - would track control changes over time
	return 0.8

func calculate_path_accuracy() -> float:
	# Placeholder - would track deviation from planned path
	return 0.9

func update_trail_color():
	var color: Color
	if trail_quality > 0.9:
		color = Color.GREEN
	elif trail_quality > 0.7:
		color = Color.YELLOW
	elif trail_quality > 0.5:
		color = Color.ORANGE
	else:
		color = Color.RED
	
	if trail_line:
		trail_line.default_color = color

func angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

func _on_area_entered(area: Area2D):
	if marked_for_death:
		return
	
	# Handle collisions
	if area.is_in_group("ships") and area.get("faction") != faction:
		mark_for_destruction("ship_impact")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
		
	marked_for_death = true
	is_alive = false
	set_physics_process(false)
	
	# Cleanup trail
	if trail_line:
		trail_line.queue_free()
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	queue_free()

# Setters for configuration
func set_target(target: Node2D):
	target_node = target

func set_flight_plan(plan_type: String, plan_data: Dictionary = {}):
	flight_plan_type = plan_type
	flight_plan_data = plan_data

func get_performance_metrics() -> Dictionary:
	# Get metrics from ProportionalNavigation if available
	if proportional_nav and proportional_nav.has_method("get_performance_metrics"):
		var nav_metrics = proportional_nav.get_performance_metrics()
		
		# Add torpedo-specific metrics
		nav_metrics["alignment_score"] = alignment_score
		nav_metrics["velocity_score"] = velocity_score
		nav_metrics["path_score"] = path_score
		nav_metrics["trail_quality"] = trail_quality
		
		return nav_metrics
	
	# Fallback metrics if no PN data
	return {
		"position_error": 100.0,
		"velocity_error": 500.0,
		"smoothness": smoothness_score,
		"anticipation_score": 0.5,
		"rotation_efficiency": alignment_score,
		"alignment_score": alignment_score,
		"velocity_score": velocity_score,
		"path_score": path_score,
		"trail_quality": trail_quality
	}

func get_trail_quality() -> float:
	return trail_quality
