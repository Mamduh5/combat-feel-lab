extends CharacterBody3D

const IDLE_ANIMATION := &"Idle_A"
const CHASE_ANIMATION := &"Walking_A"
const HIT_REACTION_ANIMATION := &"Hit_A"
const ENEMY_ATTACK_ANIMATION := &"Unarmed_Melee_Attack_Punch_A"
const ENEMY_ATTACK_2_ANIMATION := &"Unarmed_Melee_Attack_Kick"
const ENEMY_ATTACK_2_SOURCE_ANIMATION := &"Melee_Unarmed_Attack_Kick"
const PUNCH_TELEGRAPH_COLOR := Color(1.0, 0.55, 0.05)
const ATTACK_2_TELEGRAPH_COLOR := Color(1.0, 0.15, 0.1)
const DEATH_ANIMATION := &"Death_A"
const GENERAL_ANIMATION_SOURCE := preload("res://assets/third_party/KayKit_Character_Animations_1.1/Animations/gltf/Rig_Medium/Rig_Medium_General.glb")
const MOVEMENT_ANIMATION_SOURCE := preload("res://assets/third_party/KayKit_Character_Animations_1.1/Animations/gltf/Rig_Medium/Rig_Medium_MovementBasic.glb")
const ATTACK_ANIMATION_SOURCE := preload("res://assets/third_party/KayKit_Character_Animations_1.1/Animations/gltf/Rig_Medium/Rig_Medium_CombatMelee.glb")

@export var max_health: int = 100
@export var chase_speed: float = 2.8
@export var rotation_speed: float = 8.0
@export var chase_stop_distance: float = 1.6
@export var attack_range: float = 2.0
@export_range(0.0, 180.0, 0.5) var attack_facing_tolerance_degrees: float = 15.0
@export var attack_cooldown: float = 1.5
@export var telegraph_duration: float = 0.45
@export var attack_damage: int = 20
@export var attack_2_range: float = 1.6
@export var attack_2_telegraph_duration: float = 0.70
@export var attack_2_damage: int = 30
@export_range(0.0, 1.0, 0.01) var attack_2_hit_start: float = 0.45
@export_range(0.0, 1.0, 0.01) var attack_2_hit_end: float = 0.60
@export var respawn_delay: float = 2.0
@export_range(0.0, 1.0, 0.01) var enemy_hit_start: float = 0.30
@export_range(0.0, 1.0, 0.01) var enemy_hit_end: float = 0.60
@export_range(0.06, 0.10, 0.01) var hit_flash_duration: float = 0.08

@onready var health_label: Label3D = $Label3D
@onready var telegraph_label: Label3D = $TelegraphLabel
@onready var target_character: Node3D = $VisualRoot/TargetCharacter
@onready var target_animation_player: AnimationPlayer = $VisualRoot/TargetAnimationPlayer
@onready var enemy_attack_hitbox: Area3D = $VisualRoot/TargetCharacter/Rig_Medium/Skeleton3D/EnemyHandAttachment/EnemyAttackHitbox
@onready var enemy_attack_2_hitbox: Area3D = $VisualRoot/TargetCharacter/Rig_Medium/Skeleton3D/EnemyFootAttachment/EnemyAttack2Hitbox
@onready var player: CharacterBody3D = $"../Player"
@onready var body_collision: CollisionShape3D = $CollisionShape3D
@onready var hurtbox: Area3D = $Hurtbox

var current_health: int
var _enemy_attack_duration := 0.0
var _enemy_attack_2_duration := 0.0
var _selected_attack := 1
var _enemy_attack_elapsed := 0.0
var _telegraph_elapsed := 0.0
var _cooldown_remaining := 0.0
var _is_telegraphing := false
var _is_enemy_attacking := false
var _is_hit_reacting := false
var _is_dead := false
var _death_animation_finished := false
var _death_started_at_msec := 0
var _initial_global_transform: Transform3D
var _committed_attack_forward := Vector3.ZERO
var _enemy_hit_target_ids: Dictionary = {}
var _flash_material: StandardMaterial3D
var _flash_meshes: Array[MeshInstance3D] = []
var _original_material_overrides: Dictionary = {}
var _flash_generation := 0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	_initial_global_transform = global_transform
	current_health = max_health
	_update_health_label()
	_setup_target_animations()
	_setup_hit_flash()
	target_animation_player.animation_finished.connect(_on_target_animation_finished)
	_play_idle()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif velocity.y < 0.0:
		velocity.y = -0.1

	if _is_dead:
		_stop_horizontal(delta)
		_try_respawn()
	else:
		if _cooldown_remaining > 0.0:
			_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)

		if _is_enemy_attacking:
			_stop_horizontal(delta)
			_process_enemy_attack_hits(delta)
		elif _is_telegraphing:
			_stop_horizontal(delta)
			if not _player_can_be_attacked() or not _is_player_in_selected_attack_range():
				_cancel_telegraph()
			else:
				_telegraph_elapsed += delta
				if _telegraph_elapsed >= _get_selected_telegraph_duration():
					_start_enemy_attack()
		elif not _player_can_be_attacked():
			_stop_horizontal(delta)
			if not _is_hit_reacting:
				_play_idle()
		elif _cooldown_remaining <= 0.0 and not _is_hit_reacting and _is_player_in_any_attack_range():
			if _is_player_inside_attack_cone():
				_stop_horizontal(delta)
				if _select_attack_for_current_distance():
					_start_telegraph()
			else:
				_process_close_range_turn(delta)
		else:
			_process_chase(delta)

	move_and_slide()


func _process_chase(delta: float) -> void:
	var direction := player.global_position - global_position
	direction.y = 0.0
	var distance := direction.length()

	if not direction.is_zero_approx():
		direction = direction.normalized()
		_rotate_toward_direction(direction, delta)

	if distance > chase_stop_distance and not direction.is_zero_approx():
		velocity.x = direction.x * chase_speed
		velocity.z = direction.z * chase_speed
		if not _is_hit_reacting:
			_play_chase()
	else:
		_stop_horizontal(delta)
		if not _is_hit_reacting:
			_play_idle()


func _process_close_range_turn(delta: float) -> void:
	_stop_horizontal(delta)
	var direction := player.global_position - global_position
	direction.y = 0.0
	if not direction.is_zero_approx():
		_rotate_toward_direction(direction.normalized(), delta)
	if not _is_hit_reacting:
		_play_idle()


func _rotate_toward_direction(direction: Vector3, delta: float) -> void:
	var target_yaw := atan2(direction.x, direction.z)
	rotation.y = wrapf(
		lerp_angle(rotation.y, target_yaw, minf(rotation_speed * delta, 1.0)),
		-PI,
		PI
	)


func _stop_horizontal(delta: float) -> void:
	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, chase_speed * 8.0 * delta)
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z


func take_damage(amount: int) -> bool:
	if amount <= 0 or current_health <= 0 or _is_dead:
		return false

	var previous_health := current_health
	current_health = clampi(current_health - amount, 0, max_health)
	if current_health == previous_health:
		return false

	_update_health_label()
	if current_health <= 0:
		_die()
	elif not _is_telegraphing and not _is_enemy_attacking:
		_is_hit_reacting = true
		target_animation_player.play(HIT_REACTION_ANIMATION)
	_trigger_hit_flash()
	return true


func _die() -> void:
	if _is_dead:
		return

	_is_dead = true
	_death_animation_finished = false
	_death_started_at_msec = Time.get_ticks_msec()
	_is_telegraphing = false
	_is_enemy_attacking = false
	_is_hit_reacting = false
	_telegraph_elapsed = 0.0
	_enemy_attack_elapsed = 0.0
	_cooldown_remaining = 0.0
	_committed_attack_forward = Vector3.ZERO
	_selected_attack = 1
	_enemy_hit_target_ids.clear()
	velocity = Vector3.ZERO
	telegraph_label.visible = false
	enemy_attack_hitbox.set_deferred("monitoring", false)
	enemy_attack_2_hitbox.set_deferred("monitoring", false)
	target_animation_player.play(DEATH_ANIMATION)


func _finish_death_animation() -> void:
	_death_animation_finished = true
	body_collision.set_deferred("disabled", true)
	hurtbox.set_deferred("monitoring", false)
	hurtbox.set_deferred("monitorable", false)
	_try_respawn()


func _try_respawn() -> void:
	if not _is_dead or not _death_animation_finished:
		return
	var elapsed_seconds := float(Time.get_ticks_msec() - _death_started_at_msec) / 1000.0
	if elapsed_seconds < respawn_delay:
		return

	global_transform = _initial_global_transform
	velocity = Vector3.ZERO
	current_health = max_health
	_is_dead = false
	_death_animation_finished = false
	_is_telegraphing = false
	_is_enemy_attacking = false
	_is_hit_reacting = false
	_telegraph_elapsed = 0.0
	_enemy_attack_elapsed = 0.0
	_cooldown_remaining = 0.0
	_committed_attack_forward = Vector3.ZERO
	_selected_attack = 1
	_enemy_hit_target_ids.clear()
	telegraph_label.visible = false
	body_collision.set_deferred("disabled", false)
	hurtbox.set_deferred("monitoring", true)
	hurtbox.set_deferred("monitorable", true)
	enemy_attack_hitbox.set_deferred("monitoring", true)
	enemy_attack_2_hitbox.set_deferred("monitoring", true)
	_update_health_label()
	_play_idle()


func _setup_target_animations() -> void:
	var general_source := GENERAL_ANIMATION_SOURCE.instantiate()
	var general_player := general_source.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var general_library := general_player.get_animation_library(&"")
	var target_library := general_library.duplicate(true) as AnimationLibrary

	var movement_source := MOVEMENT_ANIMATION_SOURCE.instantiate()
	var movement_player := movement_source.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var chase_animation := movement_player.get_animation("Walking_A").duplicate(true) as Animation
	chase_animation.loop_mode = Animation.LOOP_LINEAR
	target_library.add_animation(CHASE_ANIMATION, chase_animation)

	var attack_source := ATTACK_ANIMATION_SOURCE.instantiate()
	var attack_player := attack_source.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var attack_animation := attack_player.get_animation("Melee_Unarmed_Attack_Punch_A").duplicate(true) as Animation
	target_library.add_animation(ENEMY_ATTACK_ANIMATION, attack_animation)
	_enemy_attack_duration = attack_animation.length
	var attack_2_animation := attack_player.get_animation(ENEMY_ATTACK_2_SOURCE_ANIMATION).duplicate(true) as Animation
	target_library.add_animation(ENEMY_ATTACK_2_ANIMATION, attack_2_animation)
	_enemy_attack_2_duration = attack_2_animation.length

	target_animation_player.add_animation_library(&"", target_library)
	general_source.free()
	movement_source.free()
	attack_source.free()


func _setup_hit_flash() -> void:
	_flash_material = StandardMaterial3D.new()
	_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_material.albedo_color = Color(1.0, 0.9, 0.65)
	_flash_material.emission_enabled = true
	_flash_material.emission = Color(1.0, 0.65, 0.25)
	_flash_material.emission_energy_multiplier = 2.0

	for child in target_character.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		_flash_meshes.append(mesh)
		_original_material_overrides[mesh] = mesh.material_override


func _start_telegraph() -> void:
	if _is_dead:
		return
	_committed_attack_forward = _get_attack_forward()
	_is_telegraphing = true
	_telegraph_elapsed = 0.0
	telegraph_label.text = "!!" if _selected_attack == 2 else "!"
	telegraph_label.modulate = ATTACK_2_TELEGRAPH_COLOR if _selected_attack == 2 else PUNCH_TELEGRAPH_COLOR
	telegraph_label.visible = true
	_play_idle()


func _cancel_telegraph() -> void:
	_is_telegraphing = false
	_telegraph_elapsed = 0.0
	_committed_attack_forward = Vector3.ZERO
	telegraph_label.visible = false
	_play_idle()


func _start_enemy_attack() -> void:
	if _is_dead:
		return
	_is_telegraphing = false
	telegraph_label.visible = false
	_is_enemy_attacking = true
	_enemy_attack_elapsed = 0.0
	_enemy_hit_target_ids.clear()
	target_animation_player.play(_get_selected_attack_animation())


func _finish_enemy_attack() -> void:
	_is_enemy_attacking = false
	_enemy_attack_elapsed = 0.0
	_committed_attack_forward = Vector3.ZERO
	_cooldown_remaining = attack_cooldown
	_play_idle()


func _process_enemy_attack_hits(delta: float) -> void:
	if _is_dead:
		return
	_enemy_attack_elapsed += delta
	var attack_duration := _get_selected_attack_duration()
	if attack_duration <= 0.0:
		return

	var normalized_progress := _enemy_attack_elapsed / attack_duration
	var hit_start := attack_2_hit_start if _selected_attack == 2 else enemy_hit_start
	var hit_end := attack_2_hit_end if _selected_attack == 2 else enemy_hit_end
	if normalized_progress < hit_start or normalized_progress > hit_end:
		return

	var active_hitbox := enemy_attack_2_hitbox if _selected_attack == 2 else enemy_attack_hitbox
	var active_damage := attack_2_damage if _selected_attack == 2 else attack_damage
	for hurtbox in active_hitbox.get_overlapping_areas():
		var target := hurtbox.get_parent()
		if target != player or not target.has_method("take_damage"):
			continue
		var target_id := target.get_instance_id()
		if _enemy_hit_target_ids.has(target_id):
			continue
		_enemy_hit_target_ids[target_id] = true
		target.take_damage(active_damage, active_hitbox.global_position)


func _get_selected_attack_animation() -> StringName:
	return ENEMY_ATTACK_2_ANIMATION if _selected_attack == 2 else ENEMY_ATTACK_ANIMATION


func _get_selected_attack_duration() -> float:
	return _enemy_attack_2_duration if _selected_attack == 2 else _enemy_attack_duration


func _get_selected_telegraph_duration() -> float:
	return attack_2_telegraph_duration if _selected_attack == 2 else telegraph_duration


func _get_player_horizontal_distance() -> float:
	var offset := player.global_position - global_position
	offset.y = 0.0
	return offset.length()


func _select_attack_for_current_distance() -> bool:
	var distance := _get_player_horizontal_distance()
	var punch_is_valid := distance <= attack_range
	var attack_2_is_valid := distance <= attack_2_range
	if not punch_is_valid and not attack_2_is_valid:
		return false
	if punch_is_valid and attack_2_is_valid:
		_selected_attack = 1 if randf() < 0.5 else 2
	else:
		_selected_attack = 1 if punch_is_valid else 2
	return true


func _player_can_be_attacked() -> bool:
	return is_instance_valid(player) and int(player.get("current_health")) > 0


func _is_player_in_any_attack_range() -> bool:
	var distance := _get_player_horizontal_distance()
	return distance <= attack_range or distance <= attack_2_range


func _is_player_in_selected_attack_range() -> bool:
	var selected_range := attack_2_range if _selected_attack == 2 else attack_range
	return _get_player_horizontal_distance() <= selected_range


func _is_player_inside_attack_cone() -> bool:
	var to_player := player.global_position - global_position
	to_player.y = 0.0
	if to_player.is_zero_approx():
		return true
	var attack_forward := _get_attack_forward()
	if attack_forward.is_zero_approx():
		return false
	var minimum_dot := cos(deg_to_rad(attack_facing_tolerance_degrees))
	return attack_forward.dot(to_player.normalized()) >= minimum_dot


func _get_attack_forward() -> Vector3:
	var attack_forward := global_transform.basis.z
	attack_forward.y = 0.0
	return attack_forward.normalized()


func _trigger_hit_flash() -> void:
	_flash_generation += 1
	var generation := _flash_generation
	for mesh in _flash_meshes:
		mesh.material_override = _flash_material

	await get_tree().create_timer(hit_flash_duration, true, false, true).timeout
	if generation != _flash_generation:
		return
	for mesh in _flash_meshes:
		if is_instance_valid(mesh):
			mesh.material_override = _original_material_overrides[mesh]


func _play_idle() -> void:
	if _is_dead:
		return
	if target_animation_player.current_animation == IDLE_ANIMATION and target_animation_player.is_playing():
		return
	target_animation_player.play(IDLE_ANIMATION)


func _play_chase() -> void:
	if _is_dead or _is_telegraphing or _is_enemy_attacking or _is_hit_reacting:
		return
	if target_animation_player.current_animation == CHASE_ANIMATION and target_animation_player.is_playing():
		return
	target_animation_player.play(CHASE_ANIMATION)


func _on_target_animation_finished(animation_name: StringName) -> void:
	if animation_name == DEATH_ANIMATION and _is_dead:
		_finish_death_animation()
	elif _is_enemy_attacking and animation_name == _get_selected_attack_animation():
		_finish_enemy_attack()
	elif animation_name == HIT_REACTION_ANIMATION:
		_is_hit_reacting = false
		if velocity.length_squared() > 0.01:
			_play_chase()
		else:
			_play_idle()
	elif animation_name == IDLE_ANIMATION and not _is_enemy_attacking:
		_play_idle()


func _update_health_label() -> void:
	health_label.text = "%d HP" % current_health
