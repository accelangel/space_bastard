# Scripts/Entities/Weapons/SmartTorpedo.gd
extends TorpedoBase
class_name SmartTorpedo

# Launch configuration
var launcher_ship: Node2D
var launch_side: int = 1

func _ready():
	super._ready()
	
	# Generate initial waypoints based on flight plan
	match flight_plan_type:
		"straight":
			generate_initial_straight_waypoints()
		"multi_angle":
			generate_initial_multi_angle_waypoints()
		"simultaneous":
			generate_initial_simultaneous_waypoints()
	
	# BatchMPCManager will update our waypoints via pull system

func generate_initial_straight_waypoints():
	# Called once at launch - BatchMPCManager will update later
	if not target_node:
		return
		
	var to_target = target_node.global_position - global_position
	var distance = to_target.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	waypoints.clear()
	
	# Calculate if we'll need velocity management
	var final_velocity_if_constant_accel = sqrt(2 * max_acceleration * distance_meters)
	var needs_velocity_management = final_velocity_if_constant_accel > 10000.0  # 10 km/s threshold
	
	if needs_velocity_management:
		generate_velocity_managed_waypoints(distance, to_target)
	else:
		generate_simple_waypoints(distance, to_target)

func generate_velocity_managed_waypoints(distance: float, to_target: Vector2):
	# Acceleration phase
	var accel_waypoint = Waypoint.new()
	accel_waypoint.position = global_position + to_target.normalized() * distance * 0.3
	accel_waypoint.velocity_target = 20000.0  # 20 km/s
	accel_waypoint.maneuver_type = "boost"
	accel_waypoint.thrust_limit = 1.0
	waypoints.append(accel_waypoint)
	
	# Cruise phase
	var cruise_waypoint = Waypoint.new()
	cruise_waypoint.position = global_position + to_target.normalized() * distance * 0.7
	cruise_waypoint.velocity_target = 20000.0
	cruise_waypoint.maneuver_type = "cruise"
	cruise_waypoint.thrust_limit = 0.8
	waypoints.append(cruise_waypoint)
	
	# Deceleration phase
	var decel_waypoint = Waypoint.new()
	decel_waypoint.position = target_node.global_position
	decel_waypoint.velocity_target = 2000.0  # 2 km/s terminal velocity
	decel_waypoint.maneuver_type = "terminal"
	decel_waypoint.thrust_limit = 1.0
	waypoints.append(decel_waypoint)

func generate_simple_waypoints(distance: float, to_target: Vector2):
	# Simple approach for close targets
	var direction = to_target.normalized()
	
	for i in range(3):
		var t = float(i) / 2.0
		var waypoint = Waypoint.new()
		# Use the actual distance parameter!
		waypoint.position = global_position + direction * (distance * t)
		waypoint.velocity_target = 2000.0
		waypoint.maneuver_type = "cruise"
		waypoint.thrust_limit = 1.0
		waypoint.max_acceleration = max_acceleration
		waypoints.append(waypoint)

func generate_initial_multi_angle_waypoints():
	# Multi-angle approach with arc
	# Implementation similar to straight but with arc waypoints
	pass

func generate_initial_simultaneous_waypoints():
	# Fan out and converge pattern
	# Implementation for simultaneous impact
	pass

# Setters
func set_launcher(ship: Node2D):
	launcher_ship = ship
	if ship and "faction" in ship:
		faction = ship.faction

func set_launch_side(side: int):
	launch_side = side

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
