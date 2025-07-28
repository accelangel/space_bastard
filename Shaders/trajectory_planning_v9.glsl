#[compute]
#version 450

// Workgroup size
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Constants
const float PI = 3.14159265359;
const float TAU = 6.28318530718;
const uint MAX_WAYPOINTS = 20;

// Maneuver types
const uint MANEUVER_CRUISE = 0;
const uint MANEUVER_BOOST = 1;
const uint MANEUVER_FLIP = 2;
const uint MANEUVER_BURN = 3;
const uint MANEUVER_CURVE = 4;
const uint MANEUVER_TERMINAL = 5;

// Trajectory types
const uint TRAJECTORY_STRAIGHT = 0;
const uint TRAJECTORY_MULTI_ANGLE = 1;
const uint TRAJECTORY_SIMULTANEOUS = 2;

// Input data structure
struct TorpedoData {
    vec2 position;
    vec2 velocity;
    float orientation;
    float angular_velocity;
    float max_acceleration;
    float max_rotation_rate;
    vec2 target_position;
    vec2 target_velocity;
    vec2 continuation_position;    // NEW
    float continuation_velocity;    // NEW
    float current_waypoint_index;   // NEW
    uint flight_plan_type;
    float flight_plan_param1;
    float flight_plan_param2;
    float flight_plan_param3;
};

// Parameters structure
struct Parameters {
    // Universal
    float waypoint_density_threshold;
    float max_waypoints;
    float meters_per_pixel;
    uint batch_size;
    
    // Straight trajectory
    float straight_lateral_separation;
    float straight_convergence_delay;
    float straight_initial_boost_duration;
    float straight_reserved;
    
    // Multi-angle
    float multi_flip_burn_threshold;
    float multi_deceleration_target;
    float multi_arc_distance;
    float multi_arc_start;
    float multi_arc_peak;
    float multi_final_approach;
    float multi_reserved1;
    float multi_reserved2;
    
    // Simultaneous
    float sim_flip_burn_threshold;
    float sim_deceleration_target;
    float sim_fan_out_rate;
    float sim_fan_duration;
    float sim_converge_start;
    float sim_converge_aggression;
    float sim_reserved1;
    float sim_reserved2;
};

// Waypoint structure (8 floats)
struct Waypoint {
    vec2 position;
    float velocity_target;
    float velocity_tolerance;
    uint maneuver_type;
    float thrust_limit;
    float reserved1;
    float reserved2;
};

// Buffers
layout(set = 0, binding = 0, std430) restrict readonly buffer InputBuffer {
    TorpedoData torpedoes[];
} input_buffer;

layout(set = 0, binding = 1, std430) restrict readonly buffer ParamsBuffer {
    Parameters params;
} params_buffer;

layout(set = 0, binding = 2, std430) restrict writeonly buffer OutputBuffer {
    Waypoint waypoints[];
} output_buffer;

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

float calculate_turn_radius(float velocity, float max_acceleration) {
    return (velocity * velocity) / max_acceleration;
}

bool needs_flip_burn(float current_velocity, float target_velocity, float distance, float max_acceleration) {
    float velocity_change = abs(target_velocity - current_velocity);
    float decel_distance = (current_velocity * current_velocity) / (2.0 * max_acceleration);
    return decel_distance > distance * 0.4 || velocity_change > 10000.0;
}

void write_waypoint(uint idx, Waypoint wp) {
    uint base = idx * 8;
    output_buffer.waypoints[idx].position = wp.position;
    output_buffer.waypoints[idx].velocity_target = wp.velocity_target;
    output_buffer.waypoints[idx].velocity_tolerance = wp.velocity_tolerance;
    output_buffer.waypoints[idx].maneuver_type = wp.maneuver_type;
    output_buffer.waypoints[idx].thrust_limit = wp.thrust_limit;
    output_buffer.waypoints[idx].reserved1 = wp.reserved1;
    output_buffer.waypoints[idx].reserved2 = wp.reserved2;
}

// Main trajectory generation functions
void generate_straight_waypoints(uint torpedo_idx, TorpedoData torpedo) {
    // PHASE 1 FIX: Always use continuation position for consistent trajectory planning
    vec2 start_position = torpedo.continuation_position;
    float start_velocity = torpedo.continuation_velocity;
    
    // Sanity check - if continuation position is impossibly far, use torpedo position
    float continuation_distance = distance(torpedo.position, torpedo.continuation_position);
    if (continuation_distance > 100000.0) {  // 100km sanity limit
        start_position = torpedo.position;
        start_velocity = length(torpedo.velocity);
    }
    
    // Now calculate trajectory from the stable start position
    vec2 to_target = torpedo.target_position - start_position;
    float distance = length(to_target);
    float distance_meters = distance * params_buffer.params.meters_per_pixel;
    vec2 direction = normalize(to_target);
    
    float lateral_offset = distance * params_buffer.params.straight_lateral_separation;
    
    // Determine if flip-burn is needed
    bool use_flip_burn = needs_flip_burn(start_velocity, 2000.0, distance_meters, torpedo.max_acceleration);
    
    uint waypoint_base = torpedo_idx * MAX_WAYPOINTS;
    uint waypoint_count = 0;
    
    // Initial lateral separation
    if (lateral_offset > 10.0) {
        Waypoint wp;
        vec2 lateral = vec2(-direction.y, direction.x) * lateral_offset;
        wp.position = start_position + to_target * 0.1 + lateral;
        wp.velocity_target = min(start_velocity + 5000.0, 20000.0);
        wp.velocity_tolerance = 1000.0;
        wp.maneuver_type = MANEUVER_BOOST;
        wp.thrust_limit = 1.0;
        write_waypoint(waypoint_base + waypoint_count++, wp);
    }
    
    if (use_flip_burn) {
        // Acceleration phase
        Waypoint accel_wp;
        accel_wp.position = start_position + to_target * 0.3;
        accel_wp.velocity_target = 50000.0;  // Max speed
        accel_wp.velocity_tolerance = 5000.0;
        accel_wp.maneuver_type = MANEUVER_BOOST;
        accel_wp.thrust_limit = 1.0;
        write_waypoint(waypoint_base + waypoint_count++, accel_wp);
        
        // Flip point
        Waypoint flip_wp;
        flip_wp.position = start_position + to_target * 0.5;
        flip_wp.velocity_target = 40000.0;
        flip_wp.velocity_tolerance = 5000.0;
        flip_wp.maneuver_type = MANEUVER_FLIP;
        flip_wp.thrust_limit = 0.0;  // No thrust during flip
        write_waypoint(waypoint_base + waypoint_count++, flip_wp);
        
        // Deceleration phase
        Waypoint decel_wp;
        decel_wp.position = start_position + to_target * 0.7;
        decel_wp.velocity_target = 5000.0;
        decel_wp.velocity_tolerance = 1000.0;
        decel_wp.maneuver_type = MANEUVER_BURN;
        decel_wp.thrust_limit = 1.0;
        write_waypoint(waypoint_base + waypoint_count++, decel_wp);
    } else {
        // Simple acceleration to cruise
        Waypoint cruise_wp;
        cruise_wp.position = start_position + to_target * 0.5;
        cruise_wp.velocity_target = 10000.0;
        cruise_wp.velocity_tolerance = 2000.0;
        cruise_wp.maneuver_type = MANEUVER_CRUISE;
        cruise_wp.thrust_limit = 0.8;
        write_waypoint(waypoint_base + waypoint_count++, cruise_wp);
    }
    
    // Convergence delay point
    float convergence_t = params_buffer.params.straight_convergence_delay;
    Waypoint converge_wp;
    converge_wp.position = start_position + to_target * convergence_t;
    converge_wp.velocity_target = 3000.0;
    converge_wp.velocity_tolerance = 500.0;
    converge_wp.maneuver_type = MANEUVER_CURVE;
    converge_wp.thrust_limit = 0.9;
    write_waypoint(waypoint_base + waypoint_count++, converge_wp);
    
    // Terminal approach
    Waypoint terminal_wp;
    terminal_wp.position = torpedo.target_position;
    terminal_wp.velocity_target = 2000.0;
    terminal_wp.velocity_tolerance = 200.0;
    terminal_wp.maneuver_type = MANEUVER_TERMINAL;
    terminal_wp.thrust_limit = 1.0;
    write_waypoint(waypoint_base + waypoint_count++, terminal_wp);
    
    // Fill remaining with zeros
    for (uint i = waypoint_count; i < MAX_WAYPOINTS; i++) {
        Waypoint empty;
        empty.position = vec2(0.0, 0.0);
        write_waypoint(waypoint_base + i, empty);
    }
}

void generate_multi_angle_waypoints(uint torpedo_idx, TorpedoData torpedo) {
    // PHASE 1 FIX: Always use continuation position for consistent trajectory planning
    vec2 start_position = torpedo.continuation_position;
    float start_velocity = torpedo.continuation_velocity;
    
    // Sanity check - if continuation position is impossibly far, use torpedo position
    float continuation_distance = distance(torpedo.position, torpedo.continuation_position);
    if (continuation_distance > 100000.0) {  // 100km sanity limit
        start_position = torpedo.position;
        start_velocity = length(torpedo.velocity);
    }
    
    vec2 to_target = torpedo.target_position - start_position;
    float distance = length(to_target);
    float distance_meters = distance * params_buffer.params.meters_per_pixel;
    vec2 direction = normalize(to_target);
    
    float approach_side = torpedo.flight_plan_param1;  // -1 or 1
    
    uint waypoint_base = torpedo_idx * MAX_WAYPOINTS;
    uint waypoint_count = 0;
    
    // Calculate arc parameters
    float arc_radius = distance * params_buffer.params.multi_arc_distance;
    vec2 perpendicular = vec2(-direction.y, direction.x) * approach_side;
    
    // Arc start point
    float arc_start_t = params_buffer.params.multi_arc_start;
    vec2 arc_center = start_position + to_target * arc_start_t + perpendicular * arc_radius;
    
    // Check if we need flip-burn based on velocity
    bool use_flip_burn = start_velocity > params_buffer.params.multi_flip_burn_threshold * 10000.0;
    
    if (use_flip_burn) {
        // Deceleration waypoint first
        Waypoint decel_wp;
        decel_wp.position = start_position + direction * distance * 0.2;
        decel_wp.velocity_target = params_buffer.params.multi_deceleration_target;
        decel_wp.velocity_tolerance = 1000.0;
        decel_wp.maneuver_type = MANEUVER_BURN;
        decel_wp.thrust_limit = 1.0;
        write_waypoint(waypoint_base + waypoint_count++, decel_wp);
    }
    
    // Arc waypoints
    float arc_angles[5] = {0.0, 0.25, 0.5, 0.75, 1.0};
    for (uint i = 0; i < 5; i++) {
        float t = arc_angles[i];
        float angle = PI * 0.5 * t * approach_side;  // 90-degree arc
        
        Waypoint arc_wp;
        vec2 offset = rotate_vector(perpendicular * arc_radius, angle);
        arc_wp.position = arc_center + offset;
        
        // Velocity profile through arc
        if (t < 0.5) {
            arc_wp.velocity_target = 5000.0 + t * 3000.0;  // Accelerate
        } else {
            arc_wp.velocity_target = 8000.0 - (t - 0.5) * 4000.0;  // Decelerate
        }
        
        arc_wp.velocity_tolerance = 1000.0;
        arc_wp.maneuver_type = MANEUVER_CURVE;
        arc_wp.thrust_limit = 0.7 + t * 0.3;  // Increase thrust through turn
        write_waypoint(waypoint_base + waypoint_count++, arc_wp);
    }
    
    // Final approach
    float final_approach_t = params_buffer.params.multi_final_approach;
    Waypoint approach_wp;
    approach_wp.position = start_position + to_target * final_approach_t;
    approach_wp.velocity_target = 3000.0;
    approach_wp.velocity_tolerance = 500.0;
    approach_wp.maneuver_type = MANEUVER_CURVE;
    approach_wp.thrust_limit = 0.9;
    write_waypoint(waypoint_base + waypoint_count++, approach_wp);
    
    // Terminal
    Waypoint terminal_wp;
    terminal_wp.position = torpedo.target_position;
    terminal_wp.velocity_target = 2000.0;
    terminal_wp.velocity_tolerance = 200.0;
    terminal_wp.maneuver_type = MANEUVER_TERMINAL;
    terminal_wp.thrust_limit = 1.0;
    write_waypoint(waypoint_base + waypoint_count++, terminal_wp);
    
    // Fill remaining
    for (uint i = waypoint_count; i < MAX_WAYPOINTS; i++) {
        Waypoint empty;
        empty.position = vec2(0.0, 0.0);
        write_waypoint(waypoint_base + i, empty);
    }
}

void generate_simultaneous_waypoints(uint torpedo_idx, TorpedoData torpedo) {
    // PHASE 1 FIX: Always use continuation position for consistent trajectory planning
    vec2 start_position = torpedo.continuation_position;
    float start_velocity = torpedo.continuation_velocity;
    
    // Sanity check - if continuation position is impossibly far, use torpedo position
    float continuation_distance = distance(torpedo.position, torpedo.continuation_position);
    if (continuation_distance > 100000.0) {  // 100km sanity limit
        start_position = torpedo.position;
        start_velocity = length(torpedo.velocity);
    }
    
    vec2 to_target = torpedo.target_position - start_position;
    float distance = length(to_target);
    float distance_meters = distance * params_buffer.params.meters_per_pixel;
    vec2 direction = normalize(to_target);
    
    float impact_time = torpedo.flight_plan_param2;
    float impact_angle = torpedo.flight_plan_param3;
    
    uint waypoint_base = torpedo_idx * MAX_WAYPOINTS;
    uint waypoint_count = 0;
    
    // Calculate required average velocity for simultaneous impact
    float required_avg_velocity = distance_meters / impact_time;
    bool needs_extreme_speed = required_avg_velocity > 20000.0;
    
    // Fan-out phase
    float fan_angle = impact_angle * params_buffer.params.sim_fan_out_rate;
    vec2 fan_direction = rotate_vector(direction, fan_angle);
    float fan_distance = distance * params_buffer.params.sim_fan_duration;
    
    Waypoint fan_wp;
    fan_wp.position = start_position + fan_direction * fan_distance;
    fan_wp.velocity_target = needs_extreme_speed ? 50000.0 : 20000.0;
    fan_wp.velocity_tolerance = 5000.0;
    fan_wp.maneuver_type = MANEUVER_BOOST;
    fan_wp.thrust_limit = 1.0;
    write_waypoint(waypoint_base + waypoint_count++, fan_wp);
    
    // Check if flip-burn needed
    if (start_velocity > params_buffer.params.sim_flip_burn_threshold * 10000.0 || needs_extreme_speed) {
        // Flip maneuver
        Waypoint flip_wp;
        flip_wp.position = start_position + to_target * 0.4;
        flip_wp.velocity_target = 30000.0;
        flip_wp.velocity_tolerance = 5000.0;
        flip_wp.maneuver_type = MANEUVER_FLIP;
        flip_wp.thrust_limit = 0.0;
        write_waypoint(waypoint_base + waypoint_count++, flip_wp);
        
        // Deceleration
        Waypoint decel_wp;
        decel_wp.position = start_position + to_target * 0.6;
        decel_wp.velocity_target = params_buffer.params.sim_deceleration_target;
        decel_wp.velocity_tolerance = 1000.0;
        decel_wp.maneuver_type = MANEUVER_BURN;
        decel_wp.thrust_limit = 1.0;
        write_waypoint(waypoint_base + waypoint_count++, decel_wp);
    }
    
    // Convergence phase
    float converge_start_t = params_buffer.params.sim_converge_start;
    vec2 impact_position = torpedo.target_position;
    vec2 impact_offset = rotate_vector(direction * distance * 0.3, impact_angle);
    vec2 converge_target = impact_position - impact_offset;
    
    Waypoint converge_wp;
    converge_wp.position = start_position + (converge_target - start_position) * converge_start_t;
    converge_wp.velocity_target = 5000.0;
    converge_wp.velocity_tolerance = 1000.0;
    converge_wp.maneuver_type = MANEUVER_CURVE;
    converge_wp.thrust_limit = 0.8;
    write_waypoint(waypoint_base + waypoint_count++, converge_wp);
    
    // Final approach from impact angle
    Waypoint approach_wp;
    approach_wp.position = converge_target;
    approach_wp.velocity_target = 3000.0;
    approach_wp.velocity_tolerance = 500.0;
    approach_wp.maneuver_type = MANEUVER_CURVE;
    approach_wp.thrust_limit = 0.9;
    write_waypoint(waypoint_base + waypoint_count++, approach_wp);
    
    // Terminal impact
    Waypoint terminal_wp;
    terminal_wp.position = torpedo.target_position;
    terminal_wp.velocity_target = 2000.0;
    terminal_wp.velocity_tolerance = 200.0;
    terminal_wp.maneuver_type = MANEUVER_TERMINAL;
    terminal_wp.thrust_limit = 1.0;
    write_waypoint(waypoint_base + waypoint_count++, terminal_wp);
    
    // Fill remaining
    for (uint i = waypoint_count; i < MAX_WAYPOINTS; i++) {
        Waypoint empty;
        empty.position = vec2(0.0, 0.0);
        write_waypoint(waypoint_base + i, empty);
    }
}

void main() {
    uint torpedo_idx = gl_GlobalInvocationID.x;
    
    // Bounds check
    if (torpedo_idx >= params_buffer.params.batch_size) return;
    
    // Get torpedo data
    TorpedoData torpedo = input_buffer.torpedoes[torpedo_idx];
    
    // Generate waypoints based on trajectory type
    switch(torpedo.flight_plan_type) {
        case TRAJECTORY_STRAIGHT:
            generate_straight_waypoints(torpedo_idx, torpedo);
            break;
        case TRAJECTORY_MULTI_ANGLE:
            generate_multi_angle_waypoints(torpedo_idx, torpedo);
            break;
        case TRAJECTORY_SIMULTANEOUS:
            generate_simultaneous_waypoints(torpedo_idx, torpedo);
            break;
        default:
            generate_straight_waypoints(torpedo_idx, torpedo);
            break;
    }
}