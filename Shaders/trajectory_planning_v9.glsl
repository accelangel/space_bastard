#[compute]
#version 450

// Workgroup size - process multiple torpedoes in parallel
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Constants
const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Trajectory types
const uint TRAJECTORY_STRAIGHT = 0;
const uint TRAJECTORY_MULTI_ANGLE = 1;
const uint TRAJECTORY_SIMULTANEOUS = 2;

// Torpedo state structure
struct TorpedoState {
    vec2 position;
    vec2 velocity;
    float orientation;
    float angular_velocity;
    float max_acceleration;
    float max_rotation_rate;
};

// Target state
struct TargetState {
    vec2 position;
    vec2 velocity;
};

// Flight plan
struct FlightPlan {
    uint type;
    float side_or_angle;
    float impact_time;
    float reserved;
};

// Waypoint output
struct Waypoint {
    vec2 position;
    float velocity_target;
    float velocity_tolerance;
    uint maneuver_type;
    float thrust_limit;
    float reserved1;
    float reserved2;
};

// Input buffers
layout(set = 0, binding = 0, std430) restrict readonly buffer TorpedoBuffer {
    TorpedoState torpedoes[];
} torpedo_buffer;

layout(set = 0, binding = 1, std430) restrict readonly buffer TargetBuffer {
    TargetState targets[];
} target_buffer;

layout(set = 0, binding = 2, std430) restrict readonly buffer SimParams {
    float dt;
    uint num_waypoints;
    float meters_per_pixel;
    uint batch_size;
} sim_params;

layout(set = 0, binding = 3, std430) restrict readonly buffer Parameters {
    vec4 layer1_params[];  // Trajectory shaping parameters
} parameters;

layout(set = 0, binding = 4, std430) restrict readonly buffer FlightPlans {
    FlightPlan plans[];
} flight_plans;

// Output buffer
layout(set = 0, binding = 5, std430) restrict writeonly buffer WaypointBuffer {
    Waypoint waypoints[];
} waypoint_buffer;

// Helper functions
float angle_difference(float from, float to) {
    float diff = to - from;
    while (diff > PI) diff -= TAU;
    while (diff < -PI) diff += TAU;
    return diff;
}

vec2 rotate_vector(vec2 v, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

void main() {
    uint torpedo_idx = gl_GlobalInvocationID.x;
    
    // Bounds check
    if (torpedo_idx >= sim_params.batch_size) return;
    
    // Get input data
    TorpedoState torpedo = torpedo_buffer.torpedoes[torpedo_idx];
    TargetState target = target_buffer.targets[torpedo_idx];
    FlightPlan plan = flight_plans.plans[torpedo_idx];
    
    // Calculate base trajectory parameters
    vec2 to_target = target.position - torpedo.position;
    float distance = length(to_target);
    float distance_meters = distance * sim_params.meters_per_pixel;
    
    // Output waypoint index for this torpedo
    uint waypoint_base = torpedo_idx * sim_params.num_waypoints;
    
    // Generate waypoints based on trajectory type
    if (plan.type == TRAJECTORY_STRAIGHT) {
        generate_straight_waypoints(torpedo, target, waypoint_base);
    }
    else if (plan.type == TRAJECTORY_MULTI_ANGLE) {
        generate_multi_angle_waypoints(torpedo, target, plan, waypoint_base);
    }
    else if (plan.type == TRAJECTORY_SIMULTANEOUS) {
        generate_simultaneous_waypoints(torpedo, target, plan, waypoint_base);
    }
}

void generate_straight_waypoints(TorpedoState torpedo, TargetState target, uint waypoint_base) {
    vec2 to_target = target.position - torpedo.position;
    float distance = length(to_target);
    
    // Check if flip-burn is needed
    float current_speed = length(torpedo.velocity);
    float max_decel = torpedo.max_acceleration;
    float stopping_distance = (current_speed * current_speed) / (2.0 * max_decel);
    
    bool needs_flip_burn = stopping_distance > distance * 0.5;
    
    for (uint i = 0; i < sim_params.num_waypoints; i++) {
        float t = float(i) / float(sim_params.num_waypoints - 1);
        
        Waypoint wp;
        wp.position = torpedo.position + to_target * t;
        
        if (needs_flip_burn && t > 0.3 && t < 0.7) {
            wp.velocity_target = 500.0;  // Decelerate to manageable speed
            wp.maneuver_type = 2;  // "burn"
            wp.thrust_limit = 1.0;
        } else {
            wp.velocity_target = 2000.0;
            wp.maneuver_type = 0;  // "cruise"
            wp.thrust_limit = 0.9;
        }
        
        wp.velocity_tolerance = 500.0;
        
        waypoint_buffer.waypoints[waypoint_base + i] = wp;
    }
}

void generate_multi_angle_waypoints(TorpedoState torpedo, TargetState target, FlightPlan plan, uint waypoint_base) {
    // Multi-angle approach with arc
    // Implementation would generate arc waypoints based on approach side
}

void generate_simultaneous_waypoints(TorpedoState torpedo, TargetState target, FlightPlan plan, uint waypoint_base) {
    // Fan out and converge for simultaneous impact
    // Implementation would coordinate impact timing
}