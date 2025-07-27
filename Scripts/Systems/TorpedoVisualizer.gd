# Scripts/Systems/TorpedoVisualizer.gd
extends Node2D
class_name TorpedoVisualizer

# Visual elements pools
var waypoint_pool: Array = []
var velocity_indicator_pool: Array = []
var trail_lines: Dictionary = {}  # torpedo_id -> Line2D

# Visual settings
var waypoint_colors = {
	"cruise": Color.WHITE,
	"boost": Color.GREEN,
	"flip": Color.YELLOW,
	"burn": Color.RED,
	"curve": Color(0.5, 0.5, 1.0),
	"terminal": Color.MAGENTA
}

func _ready():
	# Create object pools
	for i in range(1000):  # Support many waypoints
		var marker = ColorRect.new()
		marker.size = Vector2(16, 16)
		marker.visible = false
		waypoint_pool.append(marker)
		add_child(marker)
	
	# Listen to BatchMPCManager events
	var batch_manager = get_node("/root/BatchMPC")
	if batch_manager:
		batch_manager.waypoints_updated.connect(_on_waypoints_updated)
		batch_manager.batch_update_started.connect(_on_batch_started)

func _on_waypoints_updated(torpedo_id: String, waypoints: Array):
	# Find torpedo
	var torpedo = find_torpedo_by_id(torpedo_id)
	if not torpedo:
		return
	
	# Update waypoint markers
	update_waypoint_markers(torpedo, waypoints)
	
	# Flash waypoints to indicate update
	flash_waypoints(torpedo_id)

func _on_batch_started():
	# Could show a subtle indicator that update is happening
	pass

func find_torpedo_by_id(torpedo_id: String) -> Node2D:
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	for torpedo in torpedoes:
		if torpedo.get("torpedo_id") == torpedo_id:
			return torpedo
	return null

func update_waypoint_markers(torpedo: Node2D, waypoints: Array):
	# Hide all markers first
	for marker in waypoint_pool:
		marker.visible = false
	
	# Get current waypoint index from torpedo if available
	var current_waypoint_index = torpedo.get("current_waypoint_index") if "current_waypoint_index" in torpedo else -1
	
	# Show markers for waypoints
	for i in range(min(waypoints.size(), waypoint_pool.size())):
		var waypoint = waypoints[i]
		var marker = waypoint_pool[i]
		
		# Position marker at waypoint position
		marker.global_position = waypoint.position
		marker.color = waypoint_colors.get(waypoint.maneuver_type, Color.WHITE)
		
		# Highlight current waypoint
		if i == current_waypoint_index:
			marker.modulate = Color(1.5, 1.5, 1.5)  # Brighter
			marker.size = Vector2(20, 20)  # Larger
		else:
			marker.modulate = Color.WHITE
			marker.size = Vector2(16, 16)
		
		marker.visible = true
		
		# Scale based on camera zoom for visibility
		var camera = get_viewport().get_camera_2d()
		if camera:
			var zoom_scale = 1.0 / camera.zoom.x
			marker.size = marker.size * zoom_scale

func flash_waypoints(torpedo_id: String):
	# Find waypoint markers for this torpedo and flash them
	var flash_duration = 0.3
	var flash_color = Color.WHITE
	
	# Get the torpedo's waypoint markers (first N markers where N is waypoint count)
	var torpedo = find_torpedo_by_id(torpedo_id)
	if not torpedo:
		return
		
	var waypoint_count = torpedo.waypoints.size() if "waypoints" in torpedo else 0
	
	# Create flash animation
	for i in range(min(waypoint_count, waypoint_pool.size())):
		var marker = waypoint_pool[i]
		if marker.visible:
			var original_color = marker.color
			marker.color = flash_color
			
			# Tween back to original color
			var tween = create_tween()
			tween.tween_property(marker, "color", original_color, flash_duration)

func _process(_delta):
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
