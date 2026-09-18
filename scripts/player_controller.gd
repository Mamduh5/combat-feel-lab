extends CharacterBody3D

const IDLE_ANIMATION := &"Idle"
const RUN_ANIMATION := &"Running_A"
const JUMP_START_ANIMATION := &"Jump_Start"
const JUMP_IDLE_ANIMATION := &"Jump_Idle"
const JUMP_LAND_ANIMATION := &"Jump_Land"

@export var move_speed: float = 4.0
@export var jump_velocity: float = 6.0
@export var acceleration: float = 18.0
@export var deceleration: float = 22.0
@export var rotation_speed: float = 10.0
@export var mouse_sensitivity: float = 0.0025
@export_range(-89.0, 0.0, 0.5) var minimum_camera_pitch: float = -55.0
@export_range(0.0, 89.0, 0.5) var maximum_camera_pitch: float = 35.0
@export_range(1.0, 8.0, 0.1) var spring_arm_distance: float = 4.5

@onready var knight: Node3D = $Knight
@onready var animation_player: AnimationPlayer = $Knight/AnimationPlayer
@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _is_moving := false
var _is_jumping := false
var _is_landing := false
var _current_animation: StringName = &""
var _ignore_next_mouse_motion := false


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
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_ignore_next_mouse_motion = true
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

	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var target_velocity := move_direction * move_speed
	var change_rate := acceleration if move_direction != Vector3.ZERO else deceleration
	horizontal_velocity = horizontal_velocity.move_toward(target_velocity, change_rate * delta)
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z

	var was_on_floor := is_on_floor()
	if not was_on_floor:
		velocity.y -= _gravity * delta
	elif velocity.y < 0.0:
		velocity.y = -0.1

	if Input.is_action_just_pressed("jump") and was_on_floor:
		velocity.y = jump_velocity
		_is_jumping = true
		_is_landing = false
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
	if moving_now != _is_moving:
		_is_moving = moving_now
		if not _is_jumping and not _is_landing:
			_play_animation(RUN_ANIMATION if _is_moving else IDLE_ANIMATION)

	move_and_slide()

	if _is_jumping and not was_on_floor and is_on_floor():
		_is_jumping = false
		_is_landing = true
		_play_animation(JUMP_LAND_ANIMATION)


func _play_animation(animation_name: StringName) -> void:
	if _current_animation == animation_name and animation_player.is_playing():
		return
	_current_animation = animation_name
	animation_player.play(animation_name)


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name != _current_animation:
		return

	if animation_name == JUMP_START_ANIMATION:
		if _is_jumping and not is_on_floor():
			_play_animation(JUMP_IDLE_ANIMATION)
	elif animation_name == JUMP_IDLE_ANIMATION:
		if _is_jumping and not is_on_floor():
			_play_animation(JUMP_IDLE_ANIMATION)
	elif animation_name == JUMP_LAND_ANIMATION:
		_is_landing = false
		_play_animation(RUN_ANIMATION if _is_moving else IDLE_ANIMATION)
	else:
		_play_animation(_current_animation)
