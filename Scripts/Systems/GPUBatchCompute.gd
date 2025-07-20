# Scripts/Systems/GPUBatchCompute.gd
class_name GPUBatchCompute
extends RefCounted

var verbose_init: bool = false  # Set to true only when debugging GPU issues

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var pipeline_valid: bool = false  # Track pipeline validity

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
	print("[GPU Batch] === GPU INITIALIZATION DEBUG ===")
	print("[GPU Batch] Step 1: Creating rendering device...")
	
	# Try to get the main rendering device first
	rd = RenderingServer.create_local_rendering_device()
	
	if verbose_init:
		print("[GPU Batch] Device: %s" % rd.get_device_name())
		print("[GPU Batch] Vendor: %s" % rd.get_device_vendor_name())
		print("[GPU Batch] Device Limits:")
	else:
		print("[GPU Batch] GPU initialized: %s" % rd.get_device_name())
	
	if not rd:
		print("[GPU Batch] Local rendering device failed, trying global device...")
		# This is an alternative approach if local device doesn't work
		push_error("[GPU Batch] FAILED: Could not create local rendering device!")
		push_error("[GPU Batch] Your GPU might not support local compute contexts in Godot")
		push_error("[GPU Batch] This is a known limitation with some GPU/driver combinations")
		return
	
	print("[GPU Batch] SUCCESS: Rendering device created")
	print("[GPU Batch] Device: %s" % rd.get_device_name())
	print("[GPU Batch] Vendor: %s" % rd.get_device_vendor_name())
	
	# Print device limits
	print("[GPU Batch] Device Limits:")
	print("  Max workgroup size X: %d" % rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X))
	print("  Max workgroup size Y: %d" % rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_Y))
	print("  Max workgroup size Z: %d" % rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_Z))
	print("  Max workgroup invocations: %d" % rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS))
	
	print("[GPU Batch] Step 2: Loading shader...")
	_setup_shader()
	
	print("[GPU Batch] Step 3: Creating buffers...")
	if pipeline_valid:
		_create_persistent_buffers()
		print("[GPU Batch] === INITIALIZATION COMPLETE ===")
		print("[GPU Batch] GPU acceleration is READY!")
	else:
		print("[GPU Batch] === INITIALIZATION FAILED ===")
		push_error("[GPU Batch] GPU acceleration NOT available")

func _setup_shader():
	# Try to load the batch shader
	var shader_paths = [
		"res://Shaders/mpc_trajectory_batch.glsl",
		"res://Scripts/Systems/mpc_trajectory_batch.glsl",
		"res://shaders/mpc_trajectory_batch.glsl"
	]
	
	var shader_file = null
	for path in shader_paths:
		print("[GPU Batch] Trying to load shader from: %s" % path)
		if ResourceLoader.exists(path):
			shader_file = load(path)
			if shader_file:
				print("[GPU Batch] SUCCESS: Loaded shader from: %s" % path)
				break
		else:
			print("[GPU Batch] File not found at: %s" % path)
	
	if not shader_file:
		push_error("[GPU Batch] FAILED: Could not find shader file at any location!")
		push_error("[GPU Batch] Tried paths: %s" % str(shader_paths))
		return
	
	# Verify it's a shader file
	if not shader_file is RDShaderFile:
		push_error("[GPU Batch] FAILED: Loaded file is not an RDShaderFile!")
		push_error("[GPU Batch] File type is: %s" % shader_file.get_class())
		return
	
	print("[GPU Batch] Getting SPIR-V bytecode...")
	# Get SPIR-V bytecode
	var shader_spirv = shader_file.get_spirv()
	
	# Check for compilation errors FIRST
	var compile_error = shader_file.get_base_error()
	if compile_error and compile_error != "":
		push_error("[GPU Batch] SHADER COMPILATION ERROR:")
		push_error(compile_error)
		return
	
	if not shader_spirv:
		push_error("[GPU Batch] FAILED: Could not get SPIR-V bytecode!")
		push_error("[GPU Batch] The shader may have syntax errors")
		return
	
	print("[GPU Batch] Creating shader from SPIR-V...")
	# Create shader from SPIR-V - simplified validation
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	if not shader or shader == RID():
		push_error("[GPU Batch] FAILED: Could not create shader from SPIR-V!")
		push_error("[GPU Batch] The shader may have errors or use unsupported features")
		return
	
	print("[GPU Batch] Creating compute pipeline...")
	# Create compute pipeline
	pipeline = rd.compute_pipeline_create(shader)
	
	if not pipeline or pipeline == RID():
		push_error("[GPU Batch] FAILED: Could not create compute pipeline!")
		push_error("[GPU Batch] This usually means the shader has an error or uses unsupported features")
		return
	
	pipeline_valid = true
	print("[GPU Batch] SUCCESS: Shader and pipeline created!")

func _create_persistent_buffers():
	"""Create reusable buffers that persist between frames"""
	
	print("[GPU Batch] Creating persistent buffers...")
	
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
	print("[GPU Batch] Creating %d templates" % template_count)
	
	# Pack template data
	var template_data = PackedFloat32Array()
	for t in templates:
		template_data.append(t.thrust_factor)
		template_data.append(t.rotation_gain)
		template_data.append(t.initial_angle_offset)
		template_data.append(t.alignment_weight)
	
	# Create persistent buffers with max sizes
	print("[GPU Batch] Creating template buffer...")
	template_buffer = rd.storage_buffer_create(
		template_data.size() * 4,
		template_data.to_byte_array()
	)
	
	if not template_buffer or template_buffer == RID():
		push_error("[GPU Batch] Failed to create template buffer!")
		pipeline_valid = false
		return
	
	# Torpedo states buffer (2 vec4s per torpedo) - initialize with zeros
	print("[GPU Batch] Creating torpedo buffer for %d torpedoes..." % max_torpedoes)
	var torpedo_size = max_torpedoes * 2 * 4 * 4  # 2 vec4s * 4 floats * 4 bytes
	var empty_torpedo_data = PackedByteArray()
	empty_torpedo_data.resize(torpedo_size)
	torpedo_buffer = rd.storage_buffer_create(torpedo_size, empty_torpedo_data)
	
	if not torpedo_buffer or torpedo_buffer == RID():
		push_error("[GPU Batch] Failed to create torpedo buffer!")
		pipeline_valid = false
		return
	
	# Target states buffer (1 vec4 per torpedo) - initialize with zeros
	print("[GPU Batch] Creating target buffer...")
	var target_size = max_torpedoes * 4 * 4
	var empty_target_data = PackedByteArray()
	empty_target_data.resize(target_size)
	target_buffer = rd.storage_buffer_create(target_size, empty_target_data)
	
	# Sim params buffer - initialize with zeros
	print("[GPU Batch] Creating simulation parameters buffer...")
	var sim_size = 4 * 4  # 1 vec4
	var empty_sim_data = PackedByteArray()
	empty_sim_data.resize(sim_size)
	sim_buffer = rd.storage_buffer_create(sim_size, empty_sim_data)
	
	# Flight plan buffer (1 vec4 per torpedo) - initialize with zeros
	print("[GPU Batch] Creating flight plan buffer...")
	var flight_plan_size = max_torpedoes * 4 * 4
	var empty_flight_plan_data = PackedByteArray()
	empty_flight_plan_data.resize(flight_plan_size)
	flight_plan_buffer = rd.storage_buffer_create(flight_plan_size, empty_flight_plan_data)
	
	# Result buffer (1 vec4 per torpedo) - initialize with zeros
	print("[GPU Batch] Creating result buffer...")
	var result_size = max_torpedoes * 4 * 4
	var empty_result_data = PackedByteArray()
	empty_result_data.resize(result_size)
	result_buffer = rd.storage_buffer_create(result_size, empty_result_data)
	
	print("[GPU Batch] SUCCESS: Created all persistent buffers for %d torpedoes" % max_torpedoes)

func evaluate_torpedo_batch(
	torpedo_states: Array,
	target_states: Array,
	flight_plans: Array = []
) -> Array:
	"""Evaluate all torpedoes in one GPU call using persistent buffers"""
	
	if not rd or not pipeline_valid:
		push_error("[GPU Batch] GPU not initialized! pipeline_valid = %s" % pipeline_valid)
		return []
	
	var start_time = Time.get_ticks_usec()
	var batch_size = torpedo_states.size()
	
	if batch_size == 0 or batch_size > max_torpedoes:
		push_error("[GPU Batch] Invalid batch size: %d (max: %d)" % [batch_size, max_torpedoes])
		return []
	
	if debug_enabled and batch_size > 10:  # Only print for large batches
		print("[GPU Batch] Evaluating batch of %d torpedoes" % batch_size)
	
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
	
	if not uniform_set or uniform_set == RID():
		push_error("[GPU Batch] Failed to create uniform set!")
		return []
	
	# Dispatch compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Dispatch with one workgroup per torpedo (y dimension for our shader)
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
	
	if debug_enabled and batch_size > 10:  # Only print for large batches
		print("[GPU Batch] Evaluated %d torpedoes (%d trajectories) in %.2fms" % [
			batch_size, 
			batch_size * template_count,
			last_compute_time
		])
		print("[GPU Batch] First result: thrust=%.2f, rotation=%.2f" % [results[0].thrust, results[0].rotation_rate])
	
	return results

func _create_buffer_binding(binding: int, buffer: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

func is_available() -> bool:
	return rd != null and pipeline_valid

func cleanup():
	if rd:
		# Free all persistent buffers
		if template_buffer and template_buffer != RID():
			rd.free_rid(template_buffer)
		if torpedo_buffer and torpedo_buffer != RID():
			rd.free_rid(torpedo_buffer)
		if target_buffer and target_buffer != RID():
			rd.free_rid(target_buffer)
		if sim_buffer and sim_buffer != RID():
			rd.free_rid(sim_buffer)
		if flight_plan_buffer and flight_plan_buffer != RID():
			rd.free_rid(flight_plan_buffer)
		if result_buffer and result_buffer != RID():
			rd.free_rid(result_buffer)
		if shader and shader != RID():
			rd.free_rid(shader)
		if pipeline and pipeline != RID():
			rd.free_rid(pipeline)
	print("[GPU Batch] Cleaned up GPU resources")

func update_templates(evolved_templates: Array):
	"""Update GPU templates with evolved parameters"""
	
	if not rd or not template_buffer or template_buffer == RID():
		push_error("[GPU Batch] Cannot update templates - GPU not initialized!")
		return
	
	# Convert evolved templates to GPU format
	var template_data = PackedFloat32Array()
	
	for template in evolved_templates:
		template_data.append(template.get("thrust_factor", 0.9))
		template_data.append(template.get("rotation_gain", 10.0))
		template_data.append(template.get("initial_angle_offset", 0.0))
		template_data.append(template.get("alignment_weight", 0.5))
	
	# Fill remaining slots if we have fewer than expected
	while template_data.size() < template_count * 4:
		# Add default template
		template_data.append(0.9)   # thrust_factor
		template_data.append(10.0)  # rotation_gain
		template_data.append(0.0)   # initial_angle_offset
		template_data.append(0.5)   # alignment_weight
	
	# Update GPU buffer
	rd.buffer_update(template_buffer, 0, min(template_data.size() * 4, template_count * 4 * 4), template_data.to_byte_array())
	
	# Don't print every update - let BatchMPCManager handle it
	# print("[GPU Batch] Updated %d templates on GPU" % evolved_templates.size())
