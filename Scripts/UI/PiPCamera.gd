# Scripts/UI/PiPCamera.gd
extends SubViewportContainer
class_name PiPCamera

# Which ship to follow
@export_enum("Player", "Enemy") var target_ship_type: String = "Player"

# Zoom settings
@export var min_zoom: float = 0.2
@export var max_zoom: float = 1.65
@export var zoom_speed: float = 10.0
@export var default_zoom: float = 1.0

# Size and positioning - THIS will actually control the size
@export var pip_size: Vector2 = Vector2(200, 200)
@export var margin: float = 0.0

# Internal references
var camera: Camera2D
var target_ship: Node2D
var current_zoom_target: float

func _ready():
	# Add to group for detection by main camera
	add_to_group("pip_cameras")
	
	# Configure this container
	custom_minimum_size = pip_size
	size = pip_size
	stretch = true
	
	# Get the SubViewport child
	var viewport = $SubViewport
	if not viewport:
		push_error("PiPCamera: No SubViewport child found!")
		return
	
	# IMPORTANT: Actually set the viewport size to match pip_size
	viewport.size = pip_size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	
	# Create and add camera to the viewport
	camera = Camera2D.new()
	camera.name = "Camera2D"
	camera.enabled = true
	viewport.add_child(camera)
	
	# Set the viewport's world_2d to the main viewport's world
	viewport.world_2d = get_viewport().world_2d
	
	# Position AFTER setting size
	call_deferred("position_pip")
	
	# Find target ship
	call_deferred("find_target_ship")
	
	# Set initial zoom
	current_zoom_target = default_zoom
	if camera:
		camera.zoom = Vector2(default_zoom, default_zoom)
	
	# Create border and label
	create_border_and_label()
	
	# Set mouse filter to stop events from propagating
	mouse_filter = Control.MOUSE_FILTER_STOP

func position_pip():
	# Get the actual game window size
	var window_size = get_window().size
	
	if target_ship_type == "Player":
		# Top-left corner
		position = Vector2(margin, margin)
	else:
		# Bottom-right corner - calculate from actual window size
		position = Vector2(
			window_size.x - pip_size.x - margin,
			window_size.y - pip_size.y - margin
		)
	
	#print("PiP %s positioned at %s (window size: %s)" % [target_ship_type, position, window_size])

func create_border_and_label():
	# Create a Panel for the border
	var border_panel = Panel.new()
	border_panel.name = "BorderPanel"
	border_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	border_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Create a green border style
	var style = StyleBoxFlat.new()
	style.draw_center = false  # Transparent center
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color.GREEN
	
	border_panel.add_theme_stylebox_override("panel", style)
	add_child(border_panel)
	
	# Add label with background for visibility
	var label_container = PanelContainer.new()
	label_container.name = "LabelContainer"
	label_container.position = Vector2(2, 2)
	label_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Dark background for label
	var label_style = StyleBoxFlat.new()
	label_style.bg_color = Color(0, 0, 0, 0.7)
	label_style.content_margin_left = 4
	label_style.content_margin_right = 4
	label_style.content_margin_top = 2
	label_style.content_margin_bottom = 2
	label_container.add_theme_stylebox_override("panel", label_style)
	
	var label = Label.new()
	label.name = "ShipLabel"
	label.text = target_ship_type
	label.add_theme_color_override("font_color", Color.GREEN)
	label.add_theme_font_size_override("font_size", 12)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	label_container.add_child(label)
	add_child(label_container)

func find_target_ship():
	var group_name = "player_ships" if target_ship_type == "Player" else "enemy_ships"
	var ships = get_tree().get_nodes_in_group(group_name)
	
	if ships.size() > 0:
		target_ship = ships[0]
		print("PiP Camera (%s): Found target ship at %s" % [target_ship_type, target_ship.global_position])
	else:
		#print("PiP Camera (%s): No ship found!" % target_ship_type)
		return

func _physics_process(delta):
	if not camera:
		return
	
	# Update camera to follow ship
	if target_ship and is_instance_valid(target_ship):
		camera.global_position = target_ship.global_position
	else:
		# Try to find ship again
		find_target_ship()
	
	# Handle zoom
	update_zoom(delta)

func update_zoom(delta):
	# Smooth zoom interpolation
	var current_zoom = camera.zoom.x
	if abs(current_zoom - current_zoom_target) > 0.001:
		var new_zoom = lerp(current_zoom, current_zoom_target, zoom_speed * delta)
		camera.zoom = Vector2(new_zoom, new_zoom)

func _gui_input(event):
	# Handle zoom ONLY for this PiP
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom_in()
			get_viewport().set_input_as_handled()  # Stop event propagation
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom_out()
			get_viewport().set_input_as_handled()  # Stop event propagation

func zoom_in():
	current_zoom_target = clamp(current_zoom_target * 1.2, min_zoom, max_zoom)
	#print("PiP %s zoom in: %f" % [target_ship_type, current_zoom_target])

func zoom_out():
	current_zoom_target = clamp(current_zoom_target / 1.2, min_zoom, max_zoom)
	#print("PiP %s zoom out: %f" % [target_ship_type, current_zoom_target])

# Called when window is resized
func _notification(what):
	if what == NOTIFICATION_RESIZED:
		call_deferred("position_pip")
