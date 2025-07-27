# Scripts/Systems/ManualTuningParameters.gd
extends Node

# Layer 1 Parameters (Trajectory Shaping)
var layer1_params = {
	"universal": {
		"waypoint_density_threshold": 0.2,
		"max_waypoints": 100
	},
	"straight": {
		"lateral_separation": 0.1,
		"convergence_delay": 0.8,
		"initial_boost_duration": 0.15
	},
	"multi_angle": {
		"flip_burn_threshold": 1.2,
		"deceleration_target": 2000.0,
		"arc_distance": 0.3,
		"arc_start": 0.1,
		"arc_peak": 0.5,
		"final_approach": 0.8
	},
	"simultaneous": {
		"flip_burn_threshold": 1.5,
		"deceleration_target": 3000.0,
		"fan_out_rate": 1.0,
		"fan_duration": 0.25,
		"converge_start": 0.7,
		"converge_aggression": 1.0
	}
}

# Layer 2 Parameters (Execution Control)
var layer2_params = {
	"navigation_constant_N": 3.0,
	"velocity_gain": 0.001,
	"velocity_anticipation": 0.5,
	"rotation_thrust_penalty": 0.5,
	"thrust_smoothing": 0.5,
	"position_tolerance": 100.0,
	"velocity_tolerance": 500.0
}

signal parameters_changed(layer: int, param_name: String, value: float)

func get_parameter(path: String, default = null):
	# Handle nested parameters like "multi_angle.arc_distance"
	var parts = path.split(".")
	var current = layer1_params
	
	for i in range(parts.size() - 1):
		if parts[i] in current:
			current = current[parts[i]]
		else:
			return default
	
	return current.get(parts[-1], default)

func set_parameter(layer: int, param_name: String, value: float):
	if layer == 1:
		# Handle nested structure for layer 1
		# Implementation depends on UI structure
		pass
	else:
		layer2_params[param_name] = value
	
	emit_signal("parameters_changed", layer, param_name, value)

func get_layer2_parameters() -> Dictionary:
	return layer2_params.duplicate()

func get_current_parameters() -> Dictionary:
	# Return all parameters for TrajectoryPlanner
	return {
		"layer1": layer1_params.duplicate(true),
		"layer2": layer2_params.duplicate(),
		"waypoint_density_threshold": layer1_params.universal.waypoint_density_threshold
	}
