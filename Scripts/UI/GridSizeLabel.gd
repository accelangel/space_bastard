# Scripts/UI/GridSizeLabel.gd
extends Control
class_name GridSizeLabel

@export var font_size: int = 12
@export var label_color: Color = Color(0.5, 0.5, 0.5, 0.6)
@export var background_color: Color = Color(0, 0, 0, 0.5)
@export var padding: int = 3
@export var max_labels: int = 20  # Limit number of labels for performance

var grid_overlay: GridOverlay
var label_pool: Array = []  # Pool of label containers

func _ready():
	# This control spans the entire screen to position labels anywhere
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Create a pool of reusable labels
	for i in range(max_labels):
		var container = PanelContainer.new()
		container.name = "LabelContainer" + str(i)
		container.visible = false
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		
		# Style for background
		var style = StyleBoxFlat.new()
		style.bg_color = background_color
		style.corner_radius_top_left = 2
		style.corner_radius_top_right = 2
		style.corner_radius_bottom_left = 2
		style.corner_radius_bottom_right = 2
		style.content_margin_left = padding
		style.content_margin_right = padding
		style.content_margin_top = padding
		style.content_margin_bottom = padding
		container.add_theme_stylebox_override("panel", style)
		
		# Create label
		var label = Label.new()
		label.name = "Label"
		label.add_theme_font_size_override("font_size", font_size)
		label.add_theme_color_override("font_color", label_color)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_child(label)
		
		add_child(container)
		label_pool.append(container)
	
	# Find grid overlay
	call_deferred("find_grid_overlay")

func find_grid_overlay():
	# Try the new path first
	grid_overlay = get_node_or_null("/root/WorldRoot/GridCanvasLayer/GridOverlay")
	
	# Fallback to old path
	if not grid_overlay:
		grid_overlay = get_node_or_null("/root/WorldRoot/GridOverlay")
	
	if not grid_overlay:
		push_error("GridSizeLabel: Could not find GridOverlay!")

func _process(_delta):
	if not grid_overlay:
		return
	
	# Get current grid size and corner positions
	var grid_size = grid_overlay.get_current_grid_size()
	if grid_size <= 0:
		return
		
	var corners = grid_overlay.get_major_grid_corners()
	var label_text = format_grid_size(grid_size)
	
	# Hide all labels first
	for container in label_pool:
		container.visible = false
	
	# Show labels at corner positions (up to max_labels)
	var label_count = min(corners.size(), max_labels)
	for i in range(label_count):
		var container = label_pool[i]
		var label = container.get_child(0)
		
		# Update text
		label.text = label_text
		
		# Position at grid corner
		container.position = corners[i]
		container.visible = true
		
		# Fade labels near edges of screen
		var screen_size = get_viewport_rect().size
		var fade_margin = 100
		var alpha = 1.0
		
		if corners[i].x < fade_margin:
			alpha *= corners[i].x / fade_margin
		elif corners[i].x > screen_size.x - fade_margin:
			alpha *= (screen_size.x - corners[i].x) / fade_margin
			
		if corners[i].y < fade_margin:
			alpha *= corners[i].y / fade_margin
		elif corners[i].y > screen_size.y - fade_margin:
			alpha *= (screen_size.y - corners[i].y) / fade_margin
		
		container.modulate.a = alpha

func format_grid_size(meters: float) -> String:
	if meters < 1000:
		return "%d m" % int(meters)
	else:
		# Shortened format for grid labels
		if meters < 10000:
			return "%.1f km" % (meters / 1000.0)
		else:
			return "%d km" % int(meters / 1000.0)
