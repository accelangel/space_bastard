# Scripts/Systems/FireControlManager.gd - PROPER SIGNAL-BASED CLEANUP
extends Node2D
class_name FireControlManager

# System configuration
@export var engagement_range_meters: float = 15000.0
@export var min_intercept_distance_meters: float = 5.0
@export var max_simultaneous_engagements: int = 10

# Target assessment thresholds
@export var critical_time_threshold: float = 2.0
@export var short_time_threshold: float = 5.0
@export var medium_time_threshold: float = 15.0

# Multi-PDC coordination
@export var difficult_intercept_threshold: float = 0.3
@export var multi_pdc_assignment_bonus: float = 1.5

# PDC Registry
var registered_pdcs: Dictionary = {}
var pdc_assignments: Dictionary = {}
var target_assignments: Dictionary = {}

# Target tracking with proper cleanup
var tracked_targets: Dictionary = {}
var target_priorities: Array = []
var target_signal_connections: Dictionary = {}  # target_id -> signal connection

# System state
var parent_ship: Node2D
var sensor_system: SensorSystem
var ship_faction: String = "friendly"
var ship_forward_direction: Vector2 = Vector2.UP

# Performance optimization
var update_interval: float = 0.05
var update_timer: float = 0.0

# Simple target data structure - focused only on fire control
class TargetData:
	var target_id: String
	var node_ref: Node2D
	var last_position: Vector2
	var last_velocity: Vector2
	var time_to_impact: float
	var intercept_point: Vector2
	var feasibility_score: float
	var priority_score: float
	var assigned_pdcs: Array = []
	var is_critical: bool = false
	var distance_meters: float = 0.0

func _ready():
	parent_ship = get_parent()
	
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if "faction" in parent_ship:
			ship_faction = parent_ship.faction
		discover_pdcs()
	
	print("FireControlManager initialized with %d PDCs" % registered_pdcs.size())

func discover_pdcs():
	for child in parent_ship.get_children():
		if child.has_method("get_capabilities"):
			register_pdc(child)

func register_pdc(pdc_node: Node2D):
	var pdc_id = pdc_node.pdc_id
	registered_pdcs[pdc_id] = pdc_node
	pdc_assignments[pdc_id] = ""
	pdc_node.set_fire_control_manager(self)

func _physics_process(delta):
	if not sensor_system:
		return
	
	ship_forward_direction = Vector2.UP.rotated(parent_ship.rotation)
	
	update_timer += delta
	if update_timer < update_interval:
		return
	update_timer = 0.0
	
	# Main fire control loop
	update_target_tracking()
	assess_all_threats()
	optimize_pdc_assignments()
	execute_fire_missions()

func update_target_tracking():
	var current_torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	# Remove targets that no longer exist in sensor data
	var targets_to_remove = []
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		# Check if torpedo still exists in current sensor data
		if not target_data.node_ref in current_torpedoes:
			targets_to_remove.append(target_id)
			continue
		
		update_target_data(target_data)
	
	# Clean up destroyed targets
	for target_id in targets_to_remove:
		remove_target(target_id)
	
	# Add new targets
	for torpedo in current_torpedoes:
		if is_instance_valid(torpedo):
			var torpedo_id = get_torpedo_id(torpedo)
			if not tracked_targets.has(torpedo_id):
				add_new_target(torpedo)

func add_new_target(torpedo: Node2D):
	if not is_instance_valid(torpedo):
		return
		
	var target_data = TargetData.new()
	target_data.target_id = get_torpedo_id(torpedo)
	target_data.node_ref = torpedo
	
	# PROPER CLEANUP: Connect to torpedo's tree_exiting signal
	if torpedo.tree_exiting.connect(_on_target_tree_exiting.bind(target_data.target_id)):
		print("Warning: Could not connect to torpedo's tree_exiting signal")
	else:
		target_signal_connections[target_data.target_id] = torpedo
	
	update_target_data(target_data)
	tracked_targets[target_data.target_id] = target_data

# PROPER CLEANUP: Signal handler for when torpedo is destroyed
func _on_target_tree_exiting(target_id: String):
	# Called when a tracked torpedo is about to be removed from scene tree
	remove_target(target_id)

func update_target_data(target_data: TargetData):
	if not is_instance_valid(target_data.node_ref):
		return
		
	var torpedo = target_data.node_ref
	target_data.last_position = torpedo.global_position
	target_data.last_velocity = get_torpedo_velocity(torpedo)
	
	var ship_pos = parent_ship.global_position
	var relative_pos = target_data.last_position - ship_pos
	var relative_vel = target_data.last_velocity - get_ship_velocity()
	target_data.distance_meters = relative_pos.length() * WorldSettings.meters_per_pixel
	
	var closing_speed = -relative_vel.dot(relative_pos.normalized())
	if closing_speed > 0:
		target_data.time_to_impact = target_data.distance_meters / closing_speed
	else:
		target_data.time_to_impact = 999.0
	
	target_data.intercept_point = calculate_intercept_point(torpedo)
	
	if target_data.distance_meters <= engagement_range_meters:
		target_data.feasibility_score = calculate_intercept_feasibility(target_data)
	else:
		target_data.feasibility_score = 0.0
	
	target_data.is_critical = target_data.time_to_impact < critical_time_threshold and target_data.distance_meters <= engagement_range_meters

func calculate_intercept_point(torpedo: Node2D) -> Vector2:
	if not is_instance_valid(torpedo):
		return Vector2.ZERO
		
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo) / WorldSettings.meters_per_pixel
	
	var avg_pdc_pos = get_average_pdc_position()
	var distance = avg_pdc_pos.distance_to(torpedo_pos)
	var bullet_time = distance * WorldSettings.meters_per_pixel / 800.0
	
	return torpedo_pos + torpedo_vel * bullet_time

func calculate_intercept_feasibility(target_data: TargetData) -> float:
	if target_data.distance_meters > engagement_range_meters:
		return 0.0
	
	if not is_instance_valid(target_data.node_ref):
		return 0.0
	
	var ship_to_target = target_data.last_position - parent_ship.global_position
	var closing_velocity = -target_data.last_velocity.dot(ship_to_target.normalized())
	
	if closing_velocity <= 0:
		return 0.0
	
	if target_data.distance_meters < min_intercept_distance_meters:
		return 0.0
	
	var best_feasibility = 0.0
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		var pdc_feasibility = calculate_pdc_target_feasibility(pdc, target_data)
		best_feasibility = max(best_feasibility, pdc_feasibility)
	
	return best_feasibility

func calculate_pdc_target_feasibility(pdc: Node2D, target_data: TargetData) -> float:
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var world_angle = to_intercept.angle()
	var required_angle = world_angle - parent_ship.rotation
	
	# Normalize the required angle to [-PI, PI]
	while required_angle > PI:
		required_angle -= TAU
	while required_angle < -PI:
		required_angle += TAU
	
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	rotation_time += 0.2  # Add small buffer
	
	if rotation_time > target_data.time_to_impact:
		return 0.1
	
	var time_margin = target_data.time_to_impact - rotation_time
	var feasibility = clamp(time_margin / 3.0, 0.1, 1.0)
	
	return feasibility

func assess_all_threats():
	target_priorities.clear()
	
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		if not is_instance_valid(target_data.node_ref):
			continue
		
		if target_data.feasibility_score <= 0.0:
			continue
		
		calculate_target_priority(target_data)
		
		var inserted = false
		for i in range(target_priorities.size()):
			var other_data = tracked_targets[target_priorities[i]]
			if target_data.priority_score > other_data.priority_score:
				target_priorities.insert(i, target_id)
				inserted = true
				break
		
		if not inserted:
			target_priorities.append(target_id)

func calculate_target_priority(target_data: TargetData):
	var base_priority = 0.0
	
	if target_data.time_to_impact < critical_time_threshold:
		base_priority = 100.0
	elif target_data.time_to_impact < short_time_threshold:
		base_priority = 50.0
	elif target_data.time_to_impact < medium_time_threshold:
		base_priority = 25.0
	else:
		base_priority = 10.0
	
	var time_factor = 1.0 / max(target_data.time_to_impact, 0.1)
	base_priority *= time_factor
	base_priority *= target_data.feasibility_score
	
	var available_pdcs = get_available_pdc_count()
	var total_pdcs = registered_pdcs.size()
	if available_pdcs < total_pdcs * 0.3:
		base_priority *= 1.5
	
	target_data.priority_score = base_priority

func optimize_pdc_assignments():
	# Clear all assignments first
	for pdc_id in pdc_assignments:
		pdc_assignments[pdc_id] = ""
	target_assignments.clear()
	
	for target_id in target_priorities:
		if not tracked_targets.has(target_id):
			continue
			
		var target_data = tracked_targets[target_id]
		
		if not is_instance_valid(target_data.node_ref):
			continue
		
		if target_data.feasibility_score <= 0.0:
			continue
		
		var pdcs_needed = 1
		if target_data.is_critical:
			pdcs_needed = 2
		elif target_data.feasibility_score < difficult_intercept_threshold:
			pdcs_needed = 2
		
		var assigned_pdcs = assign_pdcs_to_target(target_data, pdcs_needed)
		
		if assigned_pdcs.size() > 0:
			target_assignments[target_id] = assigned_pdcs
			target_data.assigned_pdcs = assigned_pdcs

func assign_pdcs_to_target(target_data: TargetData, pdcs_needed: int) -> Array:
	var available_pdcs = []
	var assigned = []
	
	# Find all available PDCs and score them for this target
	for pdc_id in registered_pdcs:
		if pdc_assignments[pdc_id] == "":
			var pdc = registered_pdcs[pdc_id]
			var score = score_pdc_for_target(pdc, target_data)
			
			if score > 0.0:
				available_pdcs.append({"pdc_id": pdc_id, "score": score})
	
	# Sort by best score first
	available_pdcs.sort_custom(func(a, b): return a.score > b.score)
	
	# Assign the best PDCs up to the needed count
	for i in range(min(pdcs_needed, available_pdcs.size())):
		var pdc_id = available_pdcs[i].pdc_id
		pdc_assignments[pdc_id] = target_data.target_id
		assigned.append(pdc_id)
	
	return assigned

func score_pdc_for_target(pdc: Node2D, target_data: TargetData) -> float:
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var required_angle = to_intercept.angle()
	
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	if rotation_time > target_data.time_to_impact * 0.7:
		return 0.0
	
	var rotation_score = 1.0 - (rotation_time / target_data.time_to_impact)
	
	if rotation_needed < deg_to_rad(30):
		rotation_score *= 1.5
	
	return rotation_score * target_data.feasibility_score

func execute_fire_missions():
	for target_id in target_assignments:
		if not tracked_targets.has(target_id):
			continue
			
		var target_data = tracked_targets[target_id]
		
		if not is_instance_valid(target_data.node_ref):
			continue
			
		var assigned_pdcs = target_assignments[target_id]
		
		if target_data.distance_meters > engagement_range_meters:
			continue
		
		for pdc_id in assigned_pdcs:
			var pdc = registered_pdcs[pdc_id]
			
			var firing_angle = calculate_firing_solution(pdc, target_data)
			
			var is_emergency = target_data.is_critical
			pdc.set_target(target_id, firing_angle, is_emergency)
			
			if pdc.is_aimed():
				pdc.authorize_firing()

func calculate_firing_solution(pdc: Node2D, target_data: TargetData) -> float:
	if not is_instance_valid(target_data.node_ref):
		return 0.0
		
	var pdc_pos = pdc.get_muzzle_world_position()
	var target_pos = target_data.last_position
	var target_vel = target_data.last_velocity
	
	var to_target = target_pos - pdc_pos
	var distance = to_target.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	var bullet_time = distance_meters / 800.0
	
	var target_vel_pixels = target_vel / WorldSettings.meters_per_pixel
	var predicted_pos = target_pos + target_vel_pixels * bullet_time
	
	var to_intercept = predicted_pos - pdc_pos
	var world_angle = to_intercept.angle()
	
	var ship_angle = parent_ship.rotation
	var relative_angle = world_angle - ship_angle
	
	while relative_angle > PI:
		relative_angle -= TAU
	while relative_angle < -PI:
		relative_angle += TAU
	
	return relative_angle

func remove_target(target_id: String):
	# Clean removal of target from tracking with proper signal cleanup
	if not tracked_targets.has(target_id):
		return
	
	var target_data = tracked_targets[target_id]
	
	# Stop all PDCs assigned to this target
	for pdc_id in target_data.assigned_pdcs:
		if registered_pdcs.has(pdc_id):
			var pdc = registered_pdcs[pdc_id]
			pdc.stop_firing()
			pdc_assignments[pdc_id] = ""
	
	# PROPER CLEANUP: Disconnect signal if connected
	if target_signal_connections.has(target_id):
		var torpedo_node = target_signal_connections[target_id]
		if is_instance_valid(torpedo_node) and torpedo_node.tree_exiting.is_connected(_on_target_tree_exiting):
			torpedo_node.tree_exiting.disconnect(_on_target_tree_exiting)
		target_signal_connections.erase(target_id)
	
	# Clean up tracking
	tracked_targets.erase(target_id)
	if target_assignments.has(target_id):
		target_assignments.erase(target_id)
	
	var index = target_priorities.find(target_id)
	if index >= 0:
		target_priorities.remove_at(index)

# Utility functions
func get_available_pdc_count() -> int:
	var count = 0
	for pdc_id in pdc_assignments:
		if pdc_assignments[pdc_id] == "":
			count += 1
	return count

func get_average_pdc_position() -> Vector2:
	var sum = Vector2.ZERO
	var count = 0
	
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		sum += pdc.global_position
		count += 1
	
	return sum / count if count > 0 else parent_ship.global_position

func get_torpedo_id(torpedo: Node2D) -> String:
	return "torpedo_" + str(torpedo.get_instance_id())

func get_torpedo_velocity(torpedo: Node2D) -> Vector2:
	if not is_instance_valid(torpedo):
		return Vector2.ZERO
		
	if torpedo.has_method("get_velocity_mps"):
		return torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		return torpedo.velocity_mps
	return Vector2.ZERO

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

func get_debug_info() -> String:
	return "Fire Control: %d targets tracked" % tracked_targets.size()
