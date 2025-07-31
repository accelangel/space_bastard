# Scripts/Systems/TorpedoGuidanceLayer.gd
extends Node
class_name TorpedoGuidanceLayer

var torpedo: StandardTorpedo

# Guidance parameters
@export var lead_time_factor: float = 0.8  # How much to lead the target (0-1)
@export var terminal_phase_distance: float = 2000.0  # meters
@export var terminal_deceleration_factor: float = 0.8  # Still high thrust in terminal

func configure(torpedo_ref: StandardTorpedo):
	torpedo = torpedo_ref

func update_guidance(mission: TorpedoDataStructures.MissionDirective, 
					physics: TorpedoDataStructures.TorpedoPhysicsState) -> TorpedoDataStructures.GuidanceState:
	
	var guidance = TorpedoDataStructures.GuidanceState.new()
	
	# No target = no guidance (should never happen)
	if not mission.target_node or not is_instance_valid(mission.target_node):
		guidance.guidance_mode = "coast"
		guidance.thrust_level = 0.0
		return guidance
	
	# Get target info
	var target_pos = mission.target_node.global_position
	var target_vel = Vector2.ZERO
	if mission.target_node.has_method("get_velocity_mps"):
		target_vel = mission.target_node.get_velocity_mps()
	
	# Convert physics velocity from pixels/s to m/s for calculations
	var torpedo_vel_mps = physics.velocity * WorldSettings.meters_per_pixel
	
	# Calculate intercept
	var intercept_data = calculate_intercept_point(
		physics.position,
		torpedo_vel_mps,
		target_pos,
		target_vel
	)
	
	guidance.target_prediction = intercept_data.intercept_point
	guidance.time_to_impact = intercept_data.time_to_impact
	guidance.intercept_point = intercept_data.intercept_point
	guidance.target_velocity = target_vel
	
	# Determine guidance mode based on distance
	var distance_to_target = physics.position.distance_to(target_pos)
	var distance_meters = distance_to_target * WorldSettings.meters_per_pixel
	
	# ALWAYS BURN HARD
	if distance_meters < terminal_phase_distance:
		guidance.guidance_mode = "terminal"
		guidance.thrust_level = terminal_deceleration_factor  # Still 0.8, so 80% thrust
	else:
		guidance.guidance_mode = "accelerate"
		guidance.thrust_level = 1.0  # MAXIMUM BURN
	
	# Set desired state for control layer
	guidance.desired_position = guidance.intercept_point
	# Set a ridiculously high target velocity - we want to go FAST
	guidance.desired_velocity = (guidance.intercept_point - physics.position).normalized() * 100000.0  
	guidance.desired_heading = (guidance.intercept_point - physics.position).angle()
	if DebugConfig.should_log("mpc_tuning") and Engine.get_physics_frames() % 300 == 0:  # Every 5 seconds
		var to_target_direct = target_pos - physics.position
		print("[Guidance] 5s update: Direct to target: %.1f km, Time to impact: %.1fs" % [
			to_target_direct.length() * WorldSettings.meters_per_pixel / 1000.0,
			guidance.time_to_impact
		])
	
	return guidance

func calculate_intercept_point(torpedo_pos: Vector2, torpedo_vel_mps: Vector2, 
							  target_pos: Vector2, target_vel_mps: Vector2) -> Dictionary:
	
	# Debug: Check if we're predicting movement for a stationary target
	if target_vel_mps.length() < 1.0 and lead_time_factor > 0:
		print("[Guidance] WARNING: Applying lead time (%.2f) to nearly stationary target!" % lead_time_factor)
	
	# Simple linear intercept prediction
	var to_target = target_pos - torpedo_pos
	var distance_pixels = to_target.length()
	var distance_meters = distance_pixels * WorldSettings.meters_per_pixel
	
	# Initial time estimate based on current closing velocity
	var closing_velocity = torpedo_vel_mps.length()
	if closing_velocity < 1000.0:  # If we're going slow
		closing_velocity = 5000.0  # Assume we'll accelerate to at least 5 km/s
	
	var time_estimate = distance_meters / closing_velocity
	
	# Iterative refinement (2-3 iterations is usually enough)
	for i in range(3):
		# Predict where target will be
		var target_future_pos = target_pos + (target_vel_mps / WorldSettings.meters_per_pixel) * time_estimate * lead_time_factor
		
		# Recalculate time to this position
		var new_distance = torpedo_pos.distance_to(target_future_pos) * WorldSettings.meters_per_pixel
		time_estimate = new_distance / closing_velocity
	
	# Final intercept point
	var intercept_point = target_pos + (target_vel_mps / WorldSettings.meters_per_pixel) * time_estimate * lead_time_factor
	
	if DebugConfig.should_log("mpc_tuning") and torpedo.flight_phase == "launch":  # Only log once at launch
		print("[Guidance] Initial intercept calculation:")
		print("  Target pos: %s (%.1f km from torpedo)" % [target_pos, distance_meters/1000.0])
		print("  Target vel: %s m/s" % target_vel_mps)
		print("  Lead time factor: %.2f" % lead_time_factor)
		print("  Time estimate: %.2fs" % time_estimate)
		print("  Predicted movement: %s pixels" % ((target_vel_mps / WorldSettings.meters_per_pixel) * time_estimate * lead_time_factor))
		print("  Final intercept point: %s" % intercept_point)
	
	return {
		"intercept_point": intercept_point,
		"time_to_impact": time_estimate
	}
