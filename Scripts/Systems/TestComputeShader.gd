# TestComputeShader.gd
# Add this script to any Node in your scene to test if GPU compute works
extends Node

func _ready():
	print("\n=== TESTING BASIC GPU COMPUTE ===")
	
	# Create rendering device
	var rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		print("FAILED: Cannot create rendering device")
		print("Your GPU doesn't support compute shaders in Godot")
		return
	
	print("SUCCESS: Created rendering device")
	print("Device: %s" % rd.get_device_name())
	
	# Create a temporary compute shader file
	create_test_shader_file()
	
	# Load the shader file (Godot's way for compute shaders)
	var shader_file = load("res://test_compute_shader.glsl")
	if not shader_file:
		print("FAILED: Cannot load shader file")
		return
	
	print("SUCCESS: Loaded shader file")
	
	# Get SPIR-V bytecode
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	
	if not shader_spirv:
		print("FAILED: Cannot get SPIR-V bytecode")
		return
	
	print("SUCCESS: Got SPIR-V bytecode")
	
	# Create shader from SPIR-V
	var shader = rd.shader_create_from_spirv(shader_spirv)
	
	if not shader.is_valid():
		print("FAILED: Cannot create shader from SPIR-V")
		return
	
	print("SUCCESS: Created shader")
	
	# Create pipeline
	var pipeline = rd.compute_pipeline_create(shader)
	
	if not pipeline.is_valid():
		print("FAILED: Cannot create pipeline")
		return
	
	print("SUCCESS: Created pipeline")
	
	# Create test data
	var test_data = PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	var input_bytes = test_data.to_byte_array()
	var buffer = rd.storage_buffer_create(input_bytes.size(), input_bytes)
	
	# Create uniform
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(buffer)
	var uniform_set = rd.uniform_set_create([uniform], shader, 0)
	
	# Run compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, 4, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Read results
	var output_bytes = rd.buffer_get_data(buffer)
	var output = output_bytes.to_float32_array()
	
	print("Input data: %s" % str(test_data))
	print("Output data: %s" % str(output))
	
	# Verify it worked
	if output.size() == 4 and output[0] == 2.0 and output[1] == 4.0 and output[2] == 6.0 and output[3] == 8.0:
		print("\n*** GPU COMPUTE IS WORKING! ***")
		print("The problem might be with the MPC shader file loading")
	else:
		print("\n*** GPU COMPUTE FAILED ***")
		print("Results are wrong - GPU compute isn't working properly")
	
	# Cleanup
	rd.free_rid(buffer)
	rd.free_rid(uniform_set)
	rd.free_rid(shader)
	rd.free_rid(pipeline)
	
	# Clean up temporary file
	DirAccess.remove_absolute("res://test_compute_shader.glsl")
	DirAccess.remove_absolute("res://test_compute_shader.glsl.import")
	
	print("=== TEST COMPLETE ===\n")

func create_test_shader_file():
	"""Create a temporary compute shader file for testing"""
	var shader_source = """#[compute]
#version 450

layout(local_size_x = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer DataBuffer {
	float data[];
}
data_buffer;

void main() {
	uint index = gl_GlobalInvocationID.x;
	data_buffer.data[index] = data_buffer.data[index] * 2.0;
}
"""
	
	var file = FileAccess.open("res://test_compute_shader.glsl", FileAccess.WRITE)
	if file:
		file.store_string(shader_source)
		file.close()
		print("Created temporary shader file")
	else:
		print("FAILED: Cannot create temporary shader file")
