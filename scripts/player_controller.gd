extends CharacterBody3D

const IDLE_ANIMATION := &"Idle"
const RUN_ANIMATION := &"Running_A"
const SPRINT_ANIMATION := &"Running_A"
const JUMP_START_ANIMATION := &"Jump_Start"
const JUMP_IDLE_ANIMATION := &"Jump_Idle"
const JUMP_LAND_ANIMATION := &"Jump_Land"
const DASH_FORWARD_ANIMATION := &"Dodge_Forward"
const DASH_BACKWARD_ANIMATION := &"Dodge_Backward"
const DASH_LEFT_ANIMATION := &"Dodge_Left"
const DASH_RIGHT_ANIMATION := &"Dodge_Right"
const ATTACK_ANIMATION := &"1H_Melee_Attack_Slice_Diagonal"

@export var move_speed: float = 4.0
@export var sprint_speed: float = 7.5
@export var jump_velocity: float = 6.0
@export var acceleration: float = 18.0
@export var deceleration: float = 22.0
@export var rotation_speed: float = 10.0
@export var dash_distance: float = 4.5
@export var attack_duration: float = 0.75
@export var attack_damage: int = 25
@export_range(0.0, 0.20, 0.01) var hit_stop_duration: float = 0.05
@export_range(0.0, 1.0, 0.01) var attack_hit_start: float = 0.25
@export_range(0.0, 1.0, 0.01) var attack_hit_end: float = 0.75
@export var mouse_sensitivity: float = 0.0025
@export_range(-89.0, 0.0, 0.5) var minimum_camera_pitch: float = -55.0
@export_range(0.0, 89.0, 0.5) var maximum_camera_pitch: float = 35.0
@export_range(1.0, 8.0, 0.1) var spring_arm_distance: float = 4.5

@onready var knight: Node3D = $Knight
@onready var animation_player: AnimationPlayer = $Knight/AnimationPlayer
@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var sword_hitbox: Area3D = get_node("Knight/Rig/Skeleton3D/handslot_r/1H_Sword/SwordHitbox")

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _is_moving := false
var _is_sprinting := false
var _is_jumping := false
var _is_landing := false
var _is_dashing := false
var _is_attacking := false
var _dash_direction := Vector3.ZERO
var _dash_speed := 0.0
var _dash_time_remaining := 0.0
var _current_animation: StringName = &""
var _ignore_next_mouse_motion := false
var _attack_elapsed := 0.0
var _hit_target_ids: Dictionary = {}
var _hit_stop_active := false
var _hit_stop_restore_scale := 1.0
var _hit_stop_generation := 0


func _ready() -> void:
	spring_arm.spring_length = spring_arm_distance
	camera_pivot.rotation.x = deg_to_rad(-10.0)
	animation_player.animation_finished.connect(_on_animation_finished)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_ignore_next_mouse_motion = true
	_play_animation(IDLE_ANIMATION)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_ignore_next_mouse_motion = true
		elif event.is_action_pressed("attack"):
			_start_attack()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if _ignore_next_mouse_motion:
			_ignore_next_mouse_motion = false
			return
		if event.relative.length() > 100.0:
			return
		camera_pivot.rotate_y(-event.relative.x * mouse_sensitivity)
		camera_pivot.rotation.x = clampf(
			camera_pivot.rotation.x - event.relative.y * mouse_sensitivity,
			deg_to_rad(minimum_camera_pitch),
			deg_to_rad(maximum_camera_pitch)
		)


func _physics_process(delta: float) -> void:
	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var camera_forward := -camera.global_transform.basis.z
	var camera_right := camera.global_transform.basis.x
	camera_forward.y = 0.0
	camera_right.y = 0.0
	camera_forward = camera_forward.normalized()
	camera_right = camera_right.normalized()

	var move_direction := camera_right * input_vector.x + camera_forward * -input_vector.y
	if move_direction.length_squared() > 1.0:
		move_direction = move_direction.normalized()

	var was_on_floor := is_on_floor()
	if not was_on_floor:
		velocity.y -= _gravity * delta
	elif velocity.y < 0.0:
		velocity.y = -0.1

	if Input.is_action_just_pressed("dash") and was_on_floor and not _is_jumping and not _is_dashing and not _is_attacking:
		_start_dash(move_direction)

	if _is_dashing:
		var dash_step := minf(delta, _dash_time_remaining)
		var dash_velocity := _dash_direction * _dash_speed * (dash_step / delta)
		velocity.x = dash_velocity.x
		velocity.z = dash_velocity.z
		_dash_time_remaining -= dash_step
	elif _is_attacking:
		var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
		horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, deceleration * delta)
		velocity.x = horizontal_velocity.x
		velocity.z = horizontal_velocity.z
	else:
		var sprinting_now := (
			move_direction != Vector3.ZERO
			and Input.is_action_pressed("sprint")
			and was_on_floor
			and not _is_jumping
		)
		var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
		if _is_sprinting and not sprinting_now and move_direction != Vector3.ZERO:
			horizontal_velocity = horizontal_velocity.limit_length(move_speed)
		var target_speed := sprint_speed if sprinting_now else move_speed
		var target_velocity := move_direction * target_speed
		var change_rate := acceleration if move_direction != Vector3.ZERO else deceleration
		horizontal_velocity = horizontal_velocity.move_toward(target_velocity, change_rate * delta)
		velocity.x = horizontal_velocity.x
		velocity.z = horizontal_velocity.z

		if Input.is_action_just_pressed("jump") and was_on_floor:
			velocity.y = jump_velocity
			_is_jumping = true
			_is_landing = false
			sprinting_now = false
			_play_animation(JUMP_START_ANIMATION)

		if move_direction != Vector3.ZERO:
			var target_yaw := atan2(move_direction.x, move_direction.z)
			knight.rotation.y = wrapf(
				lerp_angle(
					knight.rotation.y,
					target_yaw,
					minf(rotation_speed * delta, 1.0)
				),
				-PI,
				PI
			)

		var moving_now := horizontal_velocity.length() > 0.1
		var locomotion_changed := moving_now != _is_moving or sprinting_now != _is_sprinting
		_is_moving = moving_now
		_is_sprinting = sprinting_now
		if locomotion_changed:
			if not _is_jumping and not _is_landing:
				_play_locomotion_animation()

	move_and_slide()

	if _is_attacking:
		_process_attack_hits(delta)

	if _is_dashing and _dash_time_remaining <= 0.000001:
		_finish_dash()

	if not _is_dashing and not _is_attacking and _is_jumping and not was_on_floor and is_on_floor():
		_is_jumping = false
		_is_landing = true
		_play_animation(JUMP_LAND_ANIMATION)


func _start_attack() -> void:
	if not is_on_floor() or _is_jumping or _is_dashing or _is_attacking:
		return
	if attack_duration <= 0.0:
		return

	var attack_animation := animation_player.get_animation(ATTACK_ANIMATION)
	if attack_animation == null or attack_animation.length <= 0.0:
		return
	var attack_playback_speed := attack_animation.length / attack_duration

	_is_attacking = true
	_is_landing = false
	_is_moving = false
	_is_sprinting = false
	_attack_elapsed = 0.0
	_hit_target_ids.clear()
	_play_animation(ATTACK_ANIMATION, attack_playback_speed)


func _finish_attack() -> void:
	_is_attacking = false
	_attack_elapsed = 0.0
	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	_is_moving = input_vector != Vector2.ZERO
	_is_sprinting = _is_moving and Input.is_action_pressed("sprint") and is_on_floor()
	_play_locomotion_animation()


func _process_attack_hits(delta: float) -> void:
	_attack_elapsed += delta
	var normalized_progress := _attack_elapsed / attack_duration
	if normalized_progress < attack_hit_start or normalized_progress > attack_hit_end:
		return

	for hurtbox in sword_hitbox.get_overlapping_areas():
		var target := hurtbox.get_parent()
		if not target.has_method("take_damage"):
			continue
		var target_id := target.get_instance_id()
		if _hit_target_ids.has(target_id):
			continue
		_hit_target_ids[target_id] = true
		var damage_applied := bool(target.take_damage(attack_damage))
		if damage_applied:
			_trigger_hit_stop()


func _trigger_hit_stop() -> void:
	if hit_stop_duration <= 0.0:
		return

	if not _hit_stop_active:
		_hit_stop_restore_scale = Engine.time_scale
		_hit_stop_active = true
	_hit_stop_generation += 1
	var generation := _hit_stop_generation
	Engine.time_scale = 0.0

	await get_tree().create_timer(hit_stop_duration, true, false, true).timeout
	if generation != _hit_stop_generation:
		return
	Engine.time_scale = _hit_stop_restore_scale
	_hit_stop_active = false


func _exit_tree() -> void:
	if _hit_stop_active:
		Engine.time_scale = _hit_stop_restore_scale


func _start_dash(move_direction: Vector3) -> void:
	if not is_on_floor() or _is_jumping or _is_dashing or _is_attacking:
		return

	var facing_direction := knight.global_transform.basis.z
	facing_direction.y = 0.0
	facing_direction = facing_direction.normalized()

	_dash_direction = move_direction.normalized() if move_direction != Vector3.ZERO else facing_direction

	var local_direction := knight.global_transform.basis.inverse() * _dash_direction
	var dash_animation: StringName
	if absf(local_direction.z) >= absf(local_direction.x):
		dash_animation = DASH_FORWARD_ANIMATION if local_direction.z >= 0.0 else DASH_BACKWARD_ANIMATION
	else:
		dash_animation = DASH_RIGHT_ANIMATION if local_direction.x >= 0.0 else DASH_LEFT_ANIMATION

	var dash_duration := animation_player.get_animation(dash_animation).length
	if dash_duration <= 0.0:
		return

	_is_dashing = true
	_is_landing = false
	_is_moving = false
	_is_sprinting = false
	_dash_speed = dash_distance / dash_duration
	_dash_time_remaining = dash_duration
	_play_animation(dash_animation)


func _finish_dash() -> void:
	_is_dashing = false
	_dash_direction = Vector3.ZERO
	_dash_speed = 0.0
	_dash_time_remaining = 0.0
	velocity.x = 0.0
	velocity.z = 0.0

	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	_is_moving = input_vector != Vector2.ZERO
	_is_sprinting = _is_moving and Input.is_action_pressed("sprint") and is_on_floor()
	_play_locomotion_animation()


func _play_locomotion_animation() -> void:
	if not _is_moving:
		_play_animation(IDLE_ANIMATION)
	elif _is_sprinting:
		var sprint_animation_speed := sprint_speed / move_speed if move_speed > 0.0 else 1.0
		_play_animation(SPRINT_ANIMATION, sprint_animation_speed)
	else:
		_play_animation(RUN_ANIMATION)


func _play_animation(animation_name: StringName, playback_speed: float = 1.0) -> void:
	animation_player.speed_scale = playback_speed
	if _current_animation == animation_name and animation_player.is_playing():
		return
	_current_animation = animation_name
	animation_player.play(animation_name)


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name != _current_animation:
		return

	if _is_attacking and animation_name == ATTACK_ANIMATION:
		_finish_attack()
	elif _is_dashing:
		_finish_dash()
	elif animation_name == JUMP_START_ANIMATION:
		if _is_jumping and not is_on_floor():
			_play_animation(JUMP_IDLE_ANIMATION)
	elif animation_name == JUMP_IDLE_ANIMATION:
		if _is_jumping and not is_on_floor():
			_play_animation(JUMP_IDLE_ANIMATION)
	elif animation_name == JUMP_LAND_ANIMATION:
		_is_landing = false
		_play_locomotion_animation()
	elif animation_name == RUN_ANIMATION:
		_play_locomotion_animation()
	else:
		_play_animation(_current_animation)
