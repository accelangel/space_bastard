# Scripts/UI/ManualTuningPanel.gd
extends Control
class_name ManualTuningPanel

@onready var time_scale_slider: HSlider = $VBoxContainer/TimeScaleContainer/TimeScaleSlider
@onready var time_scale_label: Label = $VBoxContainer/TimeScaleContainer/TimeScaleLabel

# Layer 1 sliders
var layer1_sliders: Dictionary = {}

# Layer 2 sliders  
var layer2_sliders: Dictionary = {}

# Performance tracking
var update_timer: float = 0.0
var update_interval: float = 0.1  # Update performance metrics 10 times per second

func _ready():
	# Set up time scale slider
	time_scale_slider.min_value = -2.0  # 0.1x speed
	time_scale_slider.max_value = 2.0   # 4.0x speed
	time_scale_slider.value = 0.0      # 1.0x speed
	time_scale_slider.value_changed.connect(_on_time_scale_changed)
	
	# Create parameter sliders
	create_layer1_sliders()
	create_layer2_sliders()
	
	# Start invisible, show when MPC tuning mode starts
	visible = false
	
	# Listen for mode changes
	GameMode.mode_changed.connect(_on_mode_changed)

func _on_mode_changed(new_mode: GameMode.Mode):
	visible = (new_mode == GameMode.Mode.MPC_TUNING)

func _on_time_scale_changed(value: float):
	# Exponential scale for intuitive control
	var time_scale = pow(2.0, value)
	Engine.time_scale = time_scale
	
	# Update label
	if time_scale < 1.0:
		time_scale_label.text = "Speed: %.1fx (Slow)" % time_scale
	elif time_scale > 1.0:
		time_scale_label.text = "Speed: %.1fx (Fast)" % time_scale
	else:
		time_scale_label.text = "Speed: 1.0x (Normal)"
	
	# Notify BatchMPCManager to use real-time updates
	var batch_manager = get_node("/root/BatchMPC")
	if batch_manager:
		batch_manager.use_real_time_updates = true

func create_layer1_sliders():
	# Create sliders for Layer 1 parameters
	# This would create UI controls for trajectory shaping parameters
	pass

func create_layer2_sliders():
	# Create sliders for Layer 2 parameters with performance indicators
	var params = ManualTuningParameters.get_layer2_parameters()
	
	for param_name in params:
		var slider_control = create_parameter_slider(param_name, params[param_name])
		layer2_sliders[param_name] = slider_control

func create_parameter_slider(param_name: String, initial_value: float) -> SliderControl:
	# Create a slider with label and performance background
	# This is a placeholder - actual implementation would create UI elements
	var control = SliderControl.new()
	control.param_name = param_name
	control.performance_score = 1.0
	return control

func _process(delta):
	if not visible:
		return
		
	update_timer += delta
	if update_timer >= update_interval:
		update_timer = 0.0
		update_layer2_feedback()

func update_layer2_feedback():
	# Get current performance metrics from torpedoes
	var metrics = collect_torpedo_metrics()
	
	# Update slider colors based on performance
	for param_name in layer2_sliders:
		var slider_control = layer2_sliders[param_name]
		
		match param_name:
			"navigation_constant_N":
				slider_control.performance_score = 1.0 - metrics.avg_position_error / 1000.0
			"velocity_gain":
				slider_control.performance_score = 1.0 - metrics.avg_velocity_error / 5000.0
			"velocity_anticipation":
				slider_control.performance_score = metrics.anticipation_quality
			"rotation_thrust_penalty":
				slider_control.performance_score = metrics.rotation_efficiency
			"thrust_smoothing":
				slider_control.performance_score = metrics.control_smoothness
		
		slider_control.update_performance_color()

func collect_torpedo_metrics() -> Dictionary:
	var metrics = {
		"avg_position_error": 0.0,
		"avg_velocity_error": 0.0,
		"anticipation_quality": 0.0,
		"rotation_efficiency": 0.0,
		"control_smoothness": 0.0
	}
	
	# Collect metrics from active torpedoes
	# This is a placeholder - actual implementation would query torpedoes
	
	return metrics

# Inner class for slider controls
class SliderControl:
	var slider: HSlider
	var label: Label
	var background: ColorRect
	var param_name: String
	var performance_score: float = 1.0
	
	func update_performance_color():
		var color: Color
		if performance_score > 0.95:
			color = Color.GREEN
		elif performance_score > 0.85:
			color = Color.YELLOW
		elif performance_score > 0.70:
			color = Color.ORANGE
		else:
			color = Color.RED
		
		if background:
			background.color = color.darkened(0.7)
