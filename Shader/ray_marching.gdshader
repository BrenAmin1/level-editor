shader_type spatial;
render_mode unshaded;

#define MAX_STEPS 15
#define MAX_DIST 15.0
#define SURF_DIST 0.1

float get_distance_to_surface(vec3 p) {
	float radius_a = 0.1;
	float radius_b = 0.05;
	float sphere_a_dist = length(p) - radius_a;
	float sphere_b_dist = length(p + vec3(0.4 * sin(TIME),0,0.4 * cos(TIME))) - radius_b;
	return min(sphere_a_dist, sphere_b_dist);
}

float ray_march(vec3 ray_origin, vec3 ray_dir) {
	float dist_from_origin = 0.0;
	float dist_to_surf;
	
	for(int i = 0; i < MAX_STEPS; i++) {
		vec3 point = ray_origin + ray_dir * dist_from_origin;
		dist_to_surf = get_distance_to_surface(point);
		dist_from_origin += dist_to_surf;
		
		if(dist_from_origin > MAX_DIST || dist_to_surf < SURF_DIST) {
			break;
		}
	}
	
	return dist_to_surf;
}

varying vec3 vert;

void vertex() {
	vert = VERTEX;
}

void fragment() {
	vec2 uv = fract(UV * vec2(3,2)) - 0.5;
	vec3 ray_origin = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD,1)).xyz;
	vec3 ray_direction = normalize(vert - ray_origin);
	vec3 color = vec3(0);
	
	float dist = ray_march(ray_origin, ray_direction);
	if(dist < SURF_DIST) { //HIT
		color.rg = vert.xy;
	}
	else { //MISSED
		discard;
	}
	
	color.rg = uv;
	ALBEDO = color;
	
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
