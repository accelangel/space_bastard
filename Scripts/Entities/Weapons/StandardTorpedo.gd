# Scripts/Entities/Weapons/StandardTorpedo.gd
extends TorpedoBase
class_name StandardTorpedo

func _ready():
	super._ready()
	
	# Standard torpedoes always use straight trajectories
	flight_plan_type = "straight"
	
	# Generate simple waypoints
	generate_initial_waypoints()

func generate_initial_waypoints():
	if not target_node:
		return
		
	var to_target = target_node.global_position - global_position
	var distance = to_target.length()
	var direction = to_target.normalized()
	
	waypoints.clear()
	
	# Simple 3-waypoint trajectory using the actual distance
	for i in range(3):
		var t = float(i) / 2.0
		var waypoint = Waypoint.new()
		waypoint.position = global_position + direction * (distance * t)
		waypoint.velocity_target = 2000.0
		waypoint.velocity_tolerance = 500.0
		waypoint.maneuver_type = "cruise"
		waypoint.thrust_limit = 1.0
		waypoint.max_acceleration = max_acceleration
		waypoints.append(waypoint)
