# Scripts/Systems/GPUBatchCompute.gd
class_name GPUBatchCompute
extends RefCounted

var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Persistent buffers for better performance
var template_buffer: RID
var template_count: int = 60  # Same as Step 1

# Performance tracking
var last_compute_time: float = 0.0
var total_evaluations: int = 0

# Debug
var debug_enabled: bool = true

func _init():
	print("[GPU Batch] Initializing batch compute system...")
	
	# Get rendering device
	rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		push_error("[GPU Batch] Failed to create rendering device!")
		return
	
	# Load batch shader
	_setup_shader()
	
	# Pre-create template buffer
	_create_template_buffer()

func _setup_shader():
	# Try to load the batch shader
	var shader_paths = [
		"res://Shaders/mpc_trajectory_batch.glsl",
		"res://Scripts/Systems/mpc_trajectory_batch.glsl",
		"res://shaders/mpc_trajectory_batch.glsl"  # lowercase variant
	]
	
	var shader_file = null
	for path in shader_paths:
		if ResourceLoader.exists(path):
			shader_file = load(path)
			if shader_file:
				print("[GPU Batch] Loaded shader from: %s" % path)
				break
		else:
			print("[GPU Batch] Shader not found at: %s" % path)
	
	if not shader_file:
		push_error("[GPU Batch] Failed to load batch shader! Tried paths: %s" % str(shader_paths))
		push_error("[GPU Batch] Please create mpc_trajectory_batch.glsl in res://Shaders/ folder")
		return
	
	# Create shader and pipeline
	var shader_spirv = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	if not shader.is_valid():
		push_error("[GPU Batch] Failed to create shader!")
		return
	
	pipeline = rd.compute_pipeline_create(shader)
	
	if not pipeline.is_valid():
		push_error("[GPU Batch] Failed to create pipeline!")
		return
	
	print("[GPU Batch] Shader initialized successfully!")

func _create_template_buffer():
	"""Create reusable template buffer"""
	var templates = []
	
	# Same template generation as Step 1
	var thrust_variations = [0.7, 0.8, 0.9, 1.0]
	var angle_variations = [-10, -5, 0, 5, 10]
	var rotation_gains = [8.0, 10.0, 12.0]
	
	for thrust in thrust_variations:
		for angle in angle_variations:
			for gain in rotation_gains:
				templates.append({
					"thrust_factor": thrust,
					"rotation_gain": gain,
					"initial_angle_offset": angle,
					"alignment_weight": 0.5
				})
	
	template_count = templates.size()
	
	# Pack template data
	var template_data = PackedFloat32Array()
	for t in templates:
		template_data.append(t.thrust_factor)
		template_data.append(t.rotation_gain)
		template_data.append(t.initial_angle_offset)
		template_data.append(t.alignment_weight)
	
	# Create persistent buffer
	template_buffer = rd.storage_buffer_create(
		template_data.size() * 4,
		template_data.to_byte_array()
	)

func evaluate_torpedo_batch(
	torpedo_states: Array,
	target_states: Array
) -> Array:
	"""Evaluate all torpedoes in one GPU call"""
	
	if not rd or not pipeline.is_valid():
		push_error("[GPU Batch] GPU not initialized!")
		return []
	
	var start_time = Time.get_ticks_usec()
	var batch_size = torpedo_states.size()
	
	if batch_size == 0:
		return []
	
	# Pack torpedo states (2 vec4s per torpedo)
	var torpedo_data = PackedFloat32Array()
	for state in torpedo_states:
		# Position and velocity
		torpedo_data.append(state.position.x)
		torpedo_data.append(state.position.y)
		torpedo_data.append(state.velocity.x)
		torpedo_data.append(state.velocity.y)
		
		# Orientation and limits
		torpedo_data.append(state.orientation)
		torpedo_data.append(state.get("angular_velocity", 0.0))
		torpedo_data.append(state.get("max_acceleration", 490.5))
		torpedo_data.append(state.get("max_rotation_rate", deg_to_rad(1080.0)))
	
	# Pack target states
	var target_data = PackedFloat32Array()
	for target in target_states:
		target_data.append(target.position.x)
		target_data.append(target.position.y)
		target_data.append(target.velocity.x)
		target_data.append(target.velocity.y)
	
	# Simulation parameters
	var sim_data = PackedFloat32Array([
		0.1,  # dt
		300,  # num_steps (30 seconds)
		0.25, # meters_per_pixel
		float(batch_size)  # num_torpedoes
	])
	
	# Result buffer (4 floats per torpedo)
	var result_data = PackedFloat32Array()
	result_data.resize(batch_size * 4)
	
	# Create buffers
	var torpedo_buffer = rd.storage_buffer_create(
		torpedo_data.size() * 4,
		torpedo_data.to_byte_array()
	)
	var target_buffer = rd.storage_buffer_create(
		target_data.size() * 4,
		target_data.to_byte_array()
	)
	var sim_buffer = rd.storage_buffer_create(
		sim_data.size() * 4,
		sim_data.to_byte_array()
	)
	var result_buffer = rd.storage_buffer_create(
		result_data.size() * 4,
		result_data.to_byte_array()
	)
	
	# Create uniform set
	var bindings = [
		_create_buffer_binding(0, torpedo_buffer),
		_create_buffer_binding(1, target_buffer),
		_create_buffer_binding(2, sim_buffer),
		_create_buffer_binding(3, template_buffer),  # Reuse persistent template buffer
		_create_buffer_binding(4, result_buffer)
	]
	
	var uniform_set = rd.uniform_set_create(bindings, shader, 0)
	
	# Dispatch compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Dispatch with one workgroup per torpedo
	rd.compute_list_dispatch(compute_list, batch_size, 1, 1)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Read results
	var output_bytes = rd.buffer_get_data(result_buffer)
	var output_data = output_bytes.to_float32_array()
	
	# Parse results
	var results = []
	for i in range(batch_size):
		var offset = i * 4
		results.append({
			"thrust": output_data[offset],
			"rotation_rate": output_data[offset + 1],
			"cost": output_data[offset + 2],
			"template_index": int(output_data[offset + 3])
		})
	
	# Clean up temporary buffers
	rd.free_rid(torpedo_buffer)
	rd.free_rid(target_buffer)
	rd.free_rid(sim_buffer)
	rd.free_rid(result_buffer)
	rd.free_rid(uniform_set)
	
	# Track performance
	last_compute_time = (Time.get_ticks_usec() - start_time) / 1000.0
	total_evaluations += batch_size * template_count
	
	if debug_enabled:
		print("[GPU Batch] Evaluated %d torpedoes (%d trajectories) in %.2fms" % [
			batch_size, 
			batch_size * template_count,
			last_compute_time
		])
	
	return results

func _create_buffer_binding(binding: int, buffer: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

func is_available() -> bool:
	return rd != null and pipeline.is_valid()

func cleanup():
	if rd:
		if template_buffer.is_valid():
			rd.free_rid(template_buffer)
		if shader.is_valid():
			rd.free_rid(shader)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
	print("[GPU Batch] Cleaned up GPU resources")
