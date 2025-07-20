# Scripts/Systems/GPUTrajectoryCompute.gd
class_name GPUTrajectoryCompute
extends RefCounted

var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Buffer references
var input_buffer: RID
var template_buffer: RID
var result_buffer: RID

# Bindings
var uniform_set: RID

# Performance tracking
var last_compute_time: float = 0.0
var total_evaluations: int = 0
var successful_inits: int = 0

# Debug
var debug_enabled: bool = true

func _init():
	print("[GPU MPC] Initializing GPU Trajectory Compute...")
	
	# Check if we can use GPU compute
	if not RenderingServer.has_method("create_local_rendering_device"):
		push_error("[GPU MPC] This version of Godot doesn't support GPU compute!")
		push_error("[GPU MPC] Requires Godot 4.0+ with Vulkan renderer")
		return
	
	# Get the rendering device
	rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		push_error("[GPU MPC] Failed to create rendering device!")
		push_error("[GPU MPC] Make sure you're using Vulkan renderer (not OpenGL)")
		return
	
	print("[GPU MPC] Rendering device created: %s" % rd.get_device_name())
	
	# Try to load and compile shader
	_setup_shader()

func _setup_shader():
	# Try multiple paths for the shader file
	var shader_paths = [
		"res://Shaders/mpc_trajectory_basic.glsl",
		"res://shaders/mpc_trajectory_basic.glsl",  # lowercase
		"res://Scripts/Shaders/mpc_trajectory_basic.glsl"  # alternative location
	]
	
	var shader_file = null
	for path in shader_paths:
		if ResourceLoader.exists(path):
			shader_file = load(path)
			if shader_file:
				print("[GPU MPC] Loaded shader from: %s" % path)
				break
	
	if not shader_file:
		push_error("[GPU MPC] Failed to load shader file! Tried paths: %s" % str(shader_paths))
		push_error("[GPU MPC] Please ensure mpc_trajectory_basic.glsl is in res://Shaders/")
		return
	
	# Check if it's a valid shader resource
	if not shader_file is RDShaderFile:
		push_error("[GPU MPC] Loaded file is not a RDShaderFile! Got: %s" % shader_file.get_class())
		return
	
	# Get SPIR-V bytecode
	var shader_spirv = shader_file.get_spirv()
	
	if not shader_spirv or shader_spirv.get_stage_count() == 0:
		push_error("[GPU MPC] Failed to get SPIR-V from shader! The shader may have compilation errors.")
		push_error("[GPU MPC] Check the shader file for syntax errors.")
		return
		
	# Create shader from SPIR-V
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	if not shader.is_valid():
		push_error("[GPU MPC] Failed to create shader from SPIR-V!")
		return
	
	# Create compute pipeline
	pipeline = rd.compute_pipeline_create(shader)
	
	if not pipeline.is_valid():
		push_error("[GPU MPC] Failed to create compute pipeline!")
		return
	
	successful_inits += 1
	print("[GPU MPC] Shader initialized successfully!")

func evaluate_templates(
	torpedo_state: Dictionary,
	target_state: Dictionary, 
	template_data: Array,
	sim_params: Dictionary = {}
) -> Dictionary:
	"""
	Evaluate trajectory templates on GPU
	Returns: {"thrust": float, "rotation_rate": float, "best_cost": float, "compute_time": float}
	"""
	
	if not rd or not pipeline.is_valid():
		push_error("[GPU MPC] GPU not initialized!")
		return {}
	
	var start_time = Time.get_ticks_usec()
	
	# Default simulation parameters
	var dt = sim_params.get("dt", 0.1)
	var num_steps = sim_params.get("num_steps", 100)
	var meters_per_pixel = sim_params.get("meters_per_pixel", 0.25)
	
	# Prepare input data
	var input_data = PackedFloat32Array()
	
	# Torpedo state (vec4)
	input_data.append(torpedo_state.position.x)
	input_data.append(torpedo_state.position.y)
	input_data.append(torpedo_state.velocity.x)
	input_data.append(torpedo_state.velocity.y)
	
	# Torpedo orient (vec4)
	input_data.append(torpedo_state.orientation)
	input_data.append(torpedo_state.get("angular_velocity", 0.0))
	input_data.append(torpedo_state.get("max_acceleration", 490.5))
	input_data.append(torpedo_state.get("max_rotation_rate", deg_to_rad(1080.0)))
	
	# Target state (vec4)
	input_data.append(target_state.position.x)
	input_data.append(target_state.position.y)
	input_data.append(target_state.velocity.x)
	input_data.append(target_state.velocity.y)
	
	# Sim params (vec4)
	input_data.append(dt)
	input_data.append(float(num_steps))
	input_data.append(meters_per_pixel)
	input_data.append(0.0)
	
	# Prepare template data
	var template_array = PackedFloat32Array()
	for template in template_data:
		template_array.append(template.get("thrust_factor", 1.0))
		template_array.append(template.get("rotation_gain", 10.0))
		template_array.append(template.get("initial_angle_offset", 0.0))
		template_array.append(template.get("alignment_weight", 0.5))
	
	# Prepare result data (costs + metadata)
	var num_templates = template_data.size()
	var result_size = num_templates + 4  # costs array + best_index + best_cost + best_control
	var result_data = PackedFloat32Array()
	result_data.resize(result_size)
	
	# Create buffers
	input_buffer = rd.storage_buffer_create(input_data.size() * 4, input_data.to_byte_array())
	template_buffer = rd.storage_buffer_create(template_array.size() * 4, template_array.to_byte_array())
	result_buffer = rd.storage_buffer_create(result_data.size() * 4, result_data.to_byte_array())
	
	# Create uniform set with bindings
	var bindings = [
		_create_buffer_binding(0, input_buffer),
		_create_buffer_binding(1, template_buffer),
		_create_buffer_binding(2, result_buffer)
	]
	
	uniform_set = rd.uniform_set_create(bindings, shader, 0)
	
	# Create compute list and dispatch
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Calculate workgroups (ceiling division)
	var workgroup_count = ceili(float(num_templates) / 32.0)

	rd.compute_list_dispatch(compute_list, workgroup_count, 1, 1)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Read back results
	var output_bytes = rd.buffer_get_data(result_buffer)
	var output_floats = output_bytes.to_float32_array()
	
	# Parse resultss
	var costs = []
	for i in range(num_templates):
		costs.append(output_floats[i])
	
	var best_index = int(output_floats[num_templates])
	var best_cost = output_floats[num_templates + 1]
	var best_thrust = output_floats[num_templates + 2]
	var best_rotation = output_floats[num_templates + 3]
	
	# Clean up buffers
	rd.free_rid(input_buffer)
	rd.free_rid(template_buffer)
	rd.free_rid(result_buffer)
	rd.free_rid(uniform_set)
	
	# Calculate timing
	var end_time = Time.get_ticks_usec()
	last_compute_time = (end_time - start_time) / 1000.0  # Convert to ms
	total_evaluations += num_templates
	
	if debug_enabled:
		print("[GPU MPC] Evaluated %d templates in %.2fms" % [num_templates, last_compute_time])
		print("[GPU MPC] Best template: %d with cost %.2f" % [best_index, best_cost])
		print("[GPU MPC] Best control: thrust=%.1f, rotation=%.1f deg/s" % [
			best_thrust, rad_to_deg(best_rotation)
		])
	
	return {
		"thrust": best_thrust,
		"rotation_rate": best_rotation,
		"best_cost": best_cost,
		"best_template_index": best_index,
		"all_costs": costs,
		"compute_time_ms": last_compute_time
	}

func _create_buffer_binding(binding: int, buffer: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

func get_stats() -> Dictionary:
	return {
		"total_evaluations": total_evaluations,
		"last_compute_time_ms": last_compute_time,
		"successful_inits": successful_inits,
		"device_name": rd.get_device_name() if rd else "No Device"
	}

func is_available() -> bool:
	return rd != null and pipeline.is_valid()

func cleanup():
	if rd:
		if shader.is_valid():
			rd.free_rid(shader)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
	print("[GPU MPC] Cleaned up GPU resources")
