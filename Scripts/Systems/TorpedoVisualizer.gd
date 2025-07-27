# Scripts/Systems/TorpedoVisualizer.gd
extends Node2D
class_name TorpedoVisualizer

# Waypoint data storage
var waypoint_data: Array = []  # Array of torpedo waypoint data
var trail_lines: Dictionary = {}  # torpedo_id -> Line2D

# Visual settings
const WAYPOINT_RADIUS_PIXELS: float = 2.5  # Screen space radius
const WAYPOINT_LINE_WIDTH: float = 0.0
var waypoint_colors = {
	"cruise": Color.BLUE,
	"boost": Color.GREEN,
	"flip": Color.YELLOW,
	"burn": Color.RED,
	"curve": Color(0.5, 0.5, 1.0),
	"terminal": Color.MAGENTA
}

func _ready():
	# Set z_index to match torpedo trails
	z_index = -1
	
	# Listen to BatchMPCManager events
	var batch_manager = get_node("/root/BatchMPC")
	if batch_manager:
		batch_manager.waypoints_updated.connect(_on_waypoints_updated)
		batch_manager.batch_update_started.connect(_on_batch_started)
		print("[TorpedoVisualizer] Connected to BatchMPCManager")

func _on_waypoints_updated(torpedo_id: String, waypoints: Array):
	print("[TorpedoVisualizer] Waypoints updated for torpedo %s, count: %d" % [torpedo_id, waypoints.size()])
	
	# Find torpedo
	var torpedo = find_torpedo_by_id(torpedo_id)
	if not torpedo:
		print("[TorpedoVisualizer] Could not find torpedo with id: %s" % torpedo_id)
		return
	
	# Store waypoint data for drawing
	var torpedo_waypoint_data = {
		"torpedo_id": torpedo_id,
		"torpedo_ref": torpedo,
		"waypoints": []
	}
	
	for i in range(waypoints.size()):
		var wp = waypoints[i]
		# Handle both direct waypoint objects and dictionaries
		var wp_position = wp.position if "position" in wp else wp.get("position", Vector2.ZERO)
		var maneuver = wp.maneuver_type if "maneuver_type" in wp else wp.get("maneuver_type", "cruise")
		
		torpedo_waypoint_data.waypoints.append({
			"world_position": wp_position,
			"color": waypoint_colors.get(maneuver, Color.WHITE),
			"is_current": false,
			"index": i
		})
		
		if i == 0:
			print("  First waypoint at: %s, type: %s" % [wp_position, maneuver])
	
	# Update or add to waypoint_data array
	var found = false
	for i in range(waypoint_data.size()):
		if waypoint_data[i].torpedo_id == torpedo_id:
			waypoint_data[i] = torpedo_waypoint_data
			found = true
			break
	
	if not found:
		waypoint_data.append(torpedo_waypoint_data)
	
	print("[TorpedoVisualizer] Total torpedoes tracked: %d" % waypoint_data.size())
	
	# Force redraw
	queue_redraw()

func _on_batch_started():
	# Could show a subtle indicator that update is happening
	pass

func find_torpedo_by_id(torpedo_id: String) -> Node2D:
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	for torpedo in torpedoes:
		if torpedo.get("torpedo_id") == torpedo_id:
			return torpedo
	return null

func _draw():
	var camera = get_viewport().get_camera_2d()
	if not camera:
		return
	
	# Calculate radius in world space based on zoom to maintain constant screen size
	var world_radius = WAYPOINT_RADIUS_PIXELS / camera.zoom.x
	var line_width = WAYPOINT_LINE_WIDTH / camera.zoom.x
	
	var waypoints_drawn = 0
	
	for torpedo_data in waypoint_data:
		var torpedo = torpedo_data.torpedo_ref
		if not is_instance_valid(torpedo):
			continue
		
		# Get current waypoint index from torpedo
		var current_idx = torpedo.get("current_waypoint_index") if "current_waypoint_index" in torpedo else -1
		
		for i in range(torpedo_data.waypoints.size()):
			var wp = torpedo_data.waypoints[i]
			
			# Determine visual properties
			var color = wp.color
			var radius = world_radius
			var width = line_width
			
			# Highlight current waypoint
			if i == current_idx:
				radius *= 1.5  # 50% bigger
				color = color.lightened(0.3)  # Brighter
				width *= 1.5
			
			# Draw filled circle in world space
			draw_circle(wp.world_position, radius, color)
			
			# Draw outline for better visibility
			draw_arc(wp.world_position, radius, 0, TAU, 32, color.darkened(0.3), width, true)
			
			waypoints_drawn += 1
	
	if waypoints_drawn > 0 and Engine.get_process_frames() % 60 == 0:
		print("[TorpedoVisualizer] Drew %d waypoints in world space" % waypoints_drawn)

func _process(_delta):
	# Redraw every frame to update with camera movement
	queue_redraw()
	
	# Update trails based on torpedo positions
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	
	for torpedo in torpedoes:
		if not is_instance_valid(torpedo):
			continue
			
		var torpedo_id = torpedo.get("torpedo_id")
		if not torpedo_id:
			continue
		
		# Update trail
		if not trail_lines.has(torpedo_id):
			create_trail_for_torpedo(torpedo_id)
		
		var trail = trail_lines[torpedo_id]
		if trail and is_instance_valid(trail):
			trail.add_point(torpedo.global_position)
			
			# Limit trail length
			if trail.get_point_count() > 500:
				trail.remove_point(0)
			
			# Update trail color based on torpedo's quality score
			if torpedo.has_method("get_trail_quality"):
				var quality = torpedo.get_trail_quality()
				trail.default_color = get_quality_color(quality)
	
	# Clean up waypoint data for destroyed torpedoes
	var valid_data = []
	for data in waypoint_data:
		if is_instance_valid(data.torpedo_ref):
			valid_data.append(data)
	waypoint_data = valid_data

func create_trail_for_torpedo(torpedo_id: String):
	var trail = Line2D.new()
	trail.width = 2.0
	trail.default_color = Color.GREEN
	trail.z_index = -1
	add_child(trail)
	trail_lines[torpedo_id] = trail

func get_quality_color(quality: float) -> Color:
	if quality > 0.9:
		return Color.GREEN
	elif quality > 0.7:
		return Color.YELLOW
	elif quality > 0.5:
		return Color.ORANGE
	else:
		return Color.RED
