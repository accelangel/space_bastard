#[compute]
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
