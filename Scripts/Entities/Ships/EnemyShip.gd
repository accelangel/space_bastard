# Scripts/Entities/Ships/EnemyShip.gd
extends BaseShip
class_name EnemyShip

# EnemyShip-specific behavior
func _ready():
	# Call parent _ready() first
	super._ready()
	
	# Set enemy-specific movement
	movement_direction = Vector2(0, 1)  # Downward
	
	print("=== ENEMY SHIP INITIALIZED ===")
	print("  Starting position: ", global_position)
	print("  Acceleration: ", acceleration_gs, " Gs (", acceleration_mps2, " m/s²)")
	print("  Movement direction: ", movement_direction)
	print("  Meters per pixel: ", meters_per_pixel)
	print("  Ship ID: ", ship_id)
	print("===============================")

func _physics_process(delta):
	# Apply constant acceleration in the movement direction
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	
	# Convert velocity from m/s to pixels/second for position update
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Debug output every 60 frames
	if Engine.get_process_frames() % 60 == 0:
		print("=== ENEMY SHIP STATUS ===")
		print("  Position: ", global_position)
		print("  Velocity: ", velocity_mps.length(), " m/s")
		print("  Ship ID: ", ship_id)
		print("========================")

# Override the base class method
func get_ship_type() -> String:
	return "EnemyShip"

# Add this method to your TargetManager.gd class

# Also add this to EnemyShip.gd _ready() function:
# Register with TargetManager
#	var target_manager = get_node_or_null("/root/TargetManager")
#	if target_manager:
#		target_manager.register_target(self)
#		add_to_group("enemy_ships")  # Make sure it's in the group

# Update all targets with current node positions (call this every frame)
func update_all_targets():
	for target_id in targets.keys():
		var target_data = targets[target_id]
		
		# Skip if node is invalid
		if not target_data.validate_target_node():
			continue
		
		# Get current position and calculate velocity
		var current_pos = target_data.target_node.global_position
		var current_vel = Vector2.ZERO
		
		# Try to get velocity from the ship if it has one
		if target_data.target_node.has_method("get_velocity_mps"):
			current_vel = target_data.target_node.get_velocity_mps()
		elif "velocity_mps" in target_data.target_node:
			current_vel = target_data.target_node.velocity_mps
		
		# Update the target data with fresh information
		target_data.update_data(current_pos, current_vel, TargetData.DataSource.DIRECT_VISUAL)

# Modify the existing _process method to include the update call
func _process(delta):
	cleanup_timer += delta
	
	# Update all target positions every frame
	update_all_targets()
	
	# Update all target data age and confidence
	for target_data in targets.values():
		target_data.update_age_and_confidence()
	
	# Periodic cleanup
	if cleanup_timer >= cleanup_interval:
		cleanup_stale_targets()
		cleanup_timer = 0.0
