# Scripts/Systems/GPUBatchCompute.gd
class_name GPUBatchCompute
extends RefCounted

var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Persistent buffers for better performance
var template_buffer: RID
var torpedo_buffer: RID
var target_buffer: RID
var sim_buffer: RID
var flight_plan_buffer: RID
var result_buffer: RID

# Buffer sizes
var max_torpedoes: int = 256
var template_count: int = 60

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
	
	# Pre-create persistent buffers
	_create_persistent_buffers()

func _setup_shader():
	# Try to load the batch shader
	var shader_paths = [
		"res://Shaders/mpc_trajectory_batch.glsl",
		"res://Scripts/Systems/mpc_trajectory_batch.glsl",
		"res://shaders/mpc_trajectory_batch.glsl"
	]
	
	var shader_file = null
	for path in shader_paths:
		if ResourceLoader.exists(path):
			shader_file = load(path)
			if shader_file:
				print("[GPU Batch] Loaded shader from: %s" % path)
				break
	
	if not shader_file:
		push_error("[GPU Batch] Failed to load batch shader!")
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

func _create_persistent_buffers():
	"""Create reusable buffers that persist between frames"""
	
	# Template buffer - same as before
	var templates = []
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
	
	# Create persistent buffers with max sizes
	template_buffer = rd.storage_buffer_create(
		template_data.size() * 4,
		template_data.to_byte_array()
	)
	
	# Torpedo states buffer (2 vec4s per torpedo) - initialize with zeros
	var torpedo_size = max_torpedoes * 2 * 4 * 4  # 2 vec4s * 4 floats * 4 bytes
	var empty_torpedo_data = PackedByteArray()
	empty_torpedo_data.resize(torpedo_size)
	torpedo_buffer = rd.storage_buffer_create(torpedo_size, empty_torpedo_data)
	
	# Target states buffer (1 vec4 per torpedo) - initialize with zeros
	var target_size = max_torpedoes * 4 * 4
	var empty_target_data = PackedByteArray()
	empty_target_data.resize(target_size)
	target_buffer = rd.storage_buffer_create(target_size, empty_target_data)
	
	# Sim params buffer - initialize with zeros
	var sim_size = 4 * 4  # 1 vec4
	var empty_sim_data = PackedByteArray()
	empty_sim_data.resize(sim_size)
	sim_buffer = rd.storage_buffer_create(sim_size, empty_sim_data)
	
	# Flight plan buffer (1 vec4 per torpedo) - initialize with zeros
	var flight_plan_size = max_torpedoes * 4 * 4
	var empty_flight_plan_data = PackedByteArray()
	empty_flight_plan_data.resize(flight_plan_size)
	flight_plan_buffer = rd.storage_buffer_create(flight_plan_size, empty_flight_plan_data)
	
	# Result buffer (1 vec4 per torpedo) - initialize with zeros
	var result_size = max_torpedoes * 4 * 4
	var empty_result_data = PackedByteArray()
	empty_result_data.resize(result_size)
	result_buffer = rd.storage_buffer_create(result_size, empty_result_data)
	
	print("[GPU Batch] Created persistent buffers for %d torpedoes" % max_torpedoes)

func evaluate_torpedo_batch(
	torpedo_states: Array,
	target_states: Array,
	flight_plans: Array = []
) -> Array:
	"""Evaluate all torpedoes in one GPU call using persistent buffers"""
	
	if not rd or not pipeline.is_valid():
		push_error("[GPU Batch] GPU not initialized!")
		return []
	
	var start_time = Time.get_ticks_usec()
	var batch_size = torpedo_states.size()
	
	if batch_size == 0 or batch_size > max_torpedoes:
		return []
	
	# Pack torpedo states (reuse buffer)
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
	
	# Pack flight plans
	var flight_plan_data = PackedFloat32Array()
	if flight_plans.size() == 0:
		# Default to straight trajectories
		for i in range(batch_size):
			flight_plan_data.append(0.0)  # TRAJECTORY_STRAIGHT
			flight_plan_data.append(0.0)
			flight_plan_data.append(0.0)
			flight_plan_data.append(0.0)
	else:
		for plan in flight_plans:
			var trajectory_type = 0.0
			if plan.get("type", "straight") == "multi_angle":
				trajectory_type = 1.0
			elif plan.get("type", "straight") == "simultaneous":
				trajectory_type = 2.0
			
			flight_plan_data.append(trajectory_type)
			flight_plan_data.append(plan.get("side", 0.0))  # or angle for simultaneous
			flight_plan_data.append(plan.get("impact_time", 0.0))
			flight_plan_data.append(0.0)  # reserved
	
	# Simulation parameters
	var sim_data = PackedFloat32Array([
		0.1,  # dt
		300,  # num_steps (30 seconds)
		0.25, # meters_per_pixel
		float(batch_size)  # num_torpedoes
	])
	
	# Update buffer contents (reuse existing buffers)
	rd.buffer_update(torpedo_buffer, 0, torpedo_data.size() * 4, torpedo_data.to_byte_array())
	rd.buffer_update(target_buffer, 0, target_data.size() * 4, target_data.to_byte_array())
	rd.buffer_update(sim_buffer, 0, sim_data.size() * 4, sim_data.to_byte_array())
	rd.buffer_update(flight_plan_buffer, 0, flight_plan_data.size() * 4, flight_plan_data.to_byte_array())
	
	# Create uniform set with persistent buffers
	var bindings = [
		_create_buffer_binding(0, torpedo_buffer),
		_create_buffer_binding(1, target_buffer),
		_create_buffer_binding(2, sim_buffer),
		_create_buffer_binding(3, template_buffer),
		_create_buffer_binding(4, flight_plan_buffer),
		_create_buffer_binding(5, result_buffer)
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
	
	# Clean up only the uniform set (buffers are persistent)
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
		# Free all persistent buffers
		if template_buffer.is_valid():
			rd.free_rid(template_buffer)
		if torpedo_buffer.is_valid():
			rd.free_rid(torpedo_buffer)
		if target_buffer.is_valid():
			rd.free_rid(target_buffer)
		if sim_buffer.is_valid():
			rd.free_rid(sim_buffer)
		if flight_plan_buffer.is_valid():
			rd.free_rid(flight_plan_buffer)
		if result_buffer.is_valid():
			rd.free_rid(result_buffer)
		if shader.is_valid():
			rd.free_rid(shader)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
	print("[GPU Batch] Cleaned up GPU resources")
