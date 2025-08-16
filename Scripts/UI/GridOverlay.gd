# Scripts/UI/GridOverlay.gd
extends Node2D
class_name GridOverlay

# Visual settings
@export var grid_color: Color = Color(0.3, 0.3, 0.3, 0.5)  # Subtle gray
@export var label_color: Color = Color(0.5, 0.5, 0.5, 0.8)  # Slightly brighter for text
@export var major_line_width: float = 2.0
@export var minor_line_width: float = 1.0
@export var target_spacing_pixels: float = 120.0  # Desired spacing on screen

# Grid behavior
@export var show_minor_grid: bool = true
@export var minor_grid_divisions: int = 5  # Minor lines between major lines

# Internal state
var camera: Camera2D
var current_grid_size_meters: float = 0.0
var major_grid_corners: Array = []  # Store screen positions of major grid corners

# Map dimensions (from your debug output)
const MAP_WIDTH: float = 4000000.0
const MAP_HEIGHT: float = 2250000.0

func _ready():
	# Find the game camera
	camera = get_tree().get_first_node_in_group("game_camera")
	if not camera:
		# Try finding by name as fallback
		camera = get_node_or_null("/root/WorldRoot/GameCamera")
	
	if not camera:
		push_error("GridOverlay: Could not find game camera!")
		return
	
	# Set z_index to render above background but below game objects
	z_index = -1

func _draw():
	if not camera:
		return
	
	# Clear previous corners
	major_grid_corners.clear()
	
	# Get current zoom level
	var zoom = camera.zoom.x
	
	# Get viewport size
	var viewport_size = get_viewport_rect().size
	
	# Calculate how much of the world we can see
	var view_half_width = (viewport_size.x / 2) / zoom
	var view_half_height = (viewport_size.y / 2) / zoom
	
	# Get the actual camera position and clamp it to match the visual clamping
	var actual_camera_pos = camera.global_position
	var camera_pos = Vector2(
		clamp(actual_camera_pos.x, -MAP_WIDTH/2 + view_half_width, MAP_WIDTH/2 - view_half_width),
		clamp(actual_camera_pos.y, -MAP_HEIGHT/2 + view_half_height, MAP_HEIGHT/2 - view_half_height)
	)
	
	# Calculate grid spacing in world units
	var world_spacing = target_spacing_pixels / zoom * WorldSettings.meters_per_pixel
	var nice_spacing = get_nice_number(world_spacing)
	
	# Store grid size for the label
	current_grid_size_meters = nice_spacing * minor_grid_divisions
	
	# Calculate visible world bounds using the clamped camera position
	var world_left = camera_pos.x - view_half_width
	var world_right = camera_pos.x + view_half_width
	var world_top = camera_pos.y - view_half_height
	var world_bottom = camera_pos.y + view_half_height
	
	# Convert nice spacing from meters to pixels
	var grid_spacing_pixels = nice_spacing / WorldSettings.meters_per_pixel
	var major_grid_spacing_pixels = grid_spacing_pixels * minor_grid_divisions
	
	# Skip if grid would be too dense
	if grid_spacing_pixels < 10:
		return
	
	# Calculate line widths that stay consistent on screen
	var major_screen_width = major_line_width / zoom
	var minor_screen_width = minor_line_width / zoom
	
	# Track major line positions
	var major_x_positions = []
	var major_y_positions = []
	
	# Draw vertical lines using indices
	var start_x_index = floor(world_left / grid_spacing_pixels) - 1
	var end_x_index = ceil(world_right / grid_spacing_pixels) + 1
	
	for i in range(start_x_index, end_x_index + 1):
		var x = i * grid_spacing_pixels
	
		# Determine if this is a major line based on index
		var is_major = (i % minor_grid_divisions) == 0
		
		if is_major or show_minor_grid:
			var line_width = major_screen_width if is_major else minor_screen_width
			var line_alpha = grid_color.a if is_major else grid_color.a * 0.5
			var line_color = Color(grid_color.r, grid_color.g, grid_color.b, line_alpha)
			
			# Draw in WORLD coordinates - this is key!
			draw_line(
				Vector2(x, world_top),
				Vector2(x, world_bottom),
				line_color,
				line_width
			)
			
			if is_major:
				major_x_positions.append(x)
	
	# Draw horizontal lines using indices
	var start_y_index = floor(world_top / grid_spacing_pixels) - 1
	var end_y_index = ceil(world_bottom / grid_spacing_pixels) + 1
	
	for i in range(start_y_index, end_y_index + 1):
		var y = i * grid_spacing_pixels
	
		# Determine if this is a major line based on index
		var is_major = (i % minor_grid_divisions) == 0
		
		if is_major or show_minor_grid:
			var line_width = major_screen_width if is_major else minor_screen_width
			var line_alpha = grid_color.a if is_major else grid_color.a * 0.5
			var line_color = Color(grid_color.r, grid_color.g, grid_color.b, line_alpha)
			
			# Draw in WORLD coordinates
			draw_line(
				Vector2(world_left, y),
				Vector2(world_right, y),
				line_color,
				line_width
			)
			
			if is_major:
				major_y_positions.append(y)
	
	# Calculate screen positions for major grid intersections
	for x_pos in major_x_positions:
		for y_pos in major_y_positions:
			# Use world position to determine if this intersection gets a label
			var world_x_index = int(round(x_pos / major_grid_spacing_pixels))
			var world_y_index = int(round(y_pos / major_grid_spacing_pixels))
			
			# Only add label if both world indices are even
			if world_x_index % 2 == 0 and world_y_index % 2 == 0:
				# Convert world position to screen position using CLAMPED camera position
				var world_pos = Vector2(x_pos, y_pos)
				var screen_pos = (world_pos - camera_pos) * zoom + viewport_size / 2
				
				# Only add if actually visible on screen (with margin)
				var margin = 100
				if screen_pos.x > -margin and screen_pos.x < viewport_size.x + margin and \
				   screen_pos.y > -margin and screen_pos.y < viewport_size.y + margin:
					screen_pos += Vector2(5, 5)
					major_grid_corners.append(screen_pos)

func is_major_gridline(value_meters: float, spacing_meters: float) -> bool:
	# Major lines are at multiples of 5x the base spacing
	var major_spacing = spacing_meters * minor_grid_divisions
	return abs(fmod(value_meters, major_spacing)) < spacing_meters * 0.75

func get_nice_number(value: float) -> float:
	if value <= 0:
		return 1.0
	
	var magnitude = pow(10, floor(log(value) / log(10)))
	var normalized = value / magnitude
	
	var nice_normalized: float
	# MUCH wider ranges for stability
	if normalized < 3.0:  # Was 2.0 - now 3x range
		nice_normalized = 1.0
	elif normalized < 7.0:  # Was 4.0 - now 2.3x range
		nice_normalized = 2.5
	elif normalized < 15.0:  # Was 8.0 - now 2x range
		nice_normalized = 5.0
	else:
		nice_normalized = 10.0
	
	return nice_normalized * magnitude

func get_current_grid_size() -> float:
	return current_grid_size_meters

func get_major_grid_corners() -> Array:
	return major_grid_corners

func _process(_delta):
	# Always redraw to ensure grid stays current with camera movement
	if camera:
		queue_redraw()
