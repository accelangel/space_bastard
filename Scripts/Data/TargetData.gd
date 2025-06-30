# Scripts/Data/TargetData.gd
class_name TargetData
extends RefCounted

# Core target information
var target_id: String
var target_node: Node2D  # Reference to actual node (can be null if lost)
var position: Vector2
var velocity: Vector2 = Vector2.ZERO
var acceleration: Vector2 = Vector2.ZERO  # For better prediction

# Data quality and timing
var confidence: float = 1.0  # 0.0 to 1.0, how reliable this data is
var last_update_time: float  # When this data was last refreshed
var data_age: float = 0.0    # How old this data is (calculated each frame)

# Prediction and tracking
var predicted_position: Vector2  # Where we think target will be
var tracking_history: Array[Vector2] = []  # Recent positions for velocity calculation
var max_history_size: int = 5

# Data source and quality
enum DataSource {
	DIRECT_VISUAL,    # Perfect information (for debugging)
	RADAR_CONTACT,    # Good but delayed
	LIDAR_CONTACT,    # Excellent but short range
	ESTIMATED,        # Extrapolated from old data
	LOST_CONTACT      # No recent data
}

var data_source: DataSource = DataSource.DIRECT_VISUAL
var detection_range: float = 0.0  # How far the detecting sensor can see

# Confidence decay parameters
var base_confidence_decay: float = 0.1  # Confidence lost per second
var max_data_age: float = 10.0  # After this many seconds, data is considered stale

func _init(id: String = "", node: Node2D = null, pos: Vector2 = Vector2.ZERO):
	target_id = id
	target_node = node
	position = pos
	predicted_position = pos
	last_update_time = Time.get_ticks_msec() / 1000.0
	
	if node:
		target_id = node.name + "_" + str(node.get_instance_id())

# Update target data with new information
func update_data(new_pos: Vector2, new_vel: Vector2 = Vector2.ZERO, source: DataSource = DataSource.DIRECT_VISUAL):
	var current_time = Time.get_ticks_msec() / 1000.0
	var delta_time = current_time - last_update_time
	
	# Store old position for velocity calculation if velocity not provided
	if new_vel == Vector2.ZERO and delta_time > 0:
		new_vel = (new_pos - position) / delta_time
	
	# Update core data
	position = new_pos
	velocity = new_vel
	data_source = source
	last_update_time = current_time
	data_age = 0.0
	
	# Boost confidence on update (but don't exceed 1.0)
	confidence = min(1.0, confidence + 0.3)
	
	# Update tracking history
	tracking_history.append(new_pos)
	if tracking_history.size() > max_history_size:
		tracking_history.pop_front()
	
	# Recalculate velocity from history if we have enough data
	if tracking_history.size() >= 3:
		_calculate_velocity_from_history()
	
	# Update predicted position
	update_prediction()

# Calculate velocity from position history (more accurate than single-frame)
func _calculate_velocity_from_history():
	if tracking_history.size() < 2:
		return
	
	var total_velocity = Vector2.ZERO
	var samples = 0
	
	for i in range(1, tracking_history.size()):
		var pos_delta = tracking_history[i] - tracking_history[i-1]
		# Assuming roughly 60 FPS, each sample is ~0.016 seconds apart
		var estimated_delta_time = 0.016
		total_velocity += pos_delta / estimated_delta_time
		samples += 1
	
	if samples > 0:
		velocity = total_velocity / samples

# Update data age and confidence decay
func update_age_and_confidence():
	var current_time = Time.get_ticks_msec() / 1000.0
	data_age = current_time - last_update_time
	
	# Decay confidence over time
	var decay_rate = base_confidence_decay
	
	# Faster decay for older data
	if data_age > 5.0:
		decay_rate *= 2.0
	if data_age > max_data_age:
		decay_rate *= 3.0
	
	confidence = max(0.0, confidence - decay_rate * (1.0/60.0))  # Assuming 60 FPS
	
	# Update data source based on age
	if data_age > max_data_age:
		data_source = DataSource.LOST_CONTACT
	elif data_age > 3.0:
		data_source = DataSource.ESTIMATED
	
	# Update prediction
	update_prediction()

# Predict where target will be at future time
func predict_position_at_time(future_time: float) -> Vector2:
	var time_delta = future_time - last_update_time
	return position + velocity * time_delta + 0.5 * acceleration * time_delta * time_delta

# Update the stored predicted position (for current time)
func update_prediction():
	var current_time = Time.get_ticks_msec() / 1000.0
	predicted_position = predict_position_at_time(current_time)

# Check if this target data is still valid/useful
func is_valid() -> bool:
	return confidence > 0.1 and data_age < max_data_age * 2.0

# Check if we have recent, reliable data
func is_reliable() -> bool:
	return confidence > 0.7 and data_age < 2.0

# Get position with confidence-based error
func get_uncertain_position() -> Vector2:
	if confidence >= 1.0:
		return predicted_position
	
	# Add uncertainty based on confidence
	var uncertainty_radius = (1.0 - confidence) * 100.0  # Max 100 pixels of error
	var random_offset = Vector2(
		randf_range(-uncertainty_radius, uncertainty_radius),
		randf_range(-uncertainty_radius, uncertainty_radius)
	)
	
	return predicted_position + random_offset

# Debug information
func get_debug_info() -> String:
	var source_name = ""
	match data_source:
		DataSource.DIRECT_VISUAL: source_name = "VISUAL"
		DataSource.RADAR_CONTACT: source_name = "RADAR"
		DataSource.LIDAR_CONTACT: source_name = "LIDAR"
		DataSource.ESTIMATED: source_name = "ESTIMATED"
		DataSource.LOST_CONTACT: source_name = "LOST"
	
	return "ID: %s | Age: %.1fs | Conf: %.2f | Source: %s | Vel: %.1fm/s" % [
		target_id, data_age, confidence, source_name, velocity.length() * WorldSettings.meters_per_pixel
	]

# Check if the actual target node still exists
func validate_target_node() -> bool:
	if not target_node or not is_instance_valid(target_node):
		target_node = null
		return false
	return true
