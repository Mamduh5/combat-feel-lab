extends Node3D

const IDLE_ANIMATION := &"Idle_A"
const HIT_REACTION_ANIMATION := &"Hit_A"
const ENEMY_ATTACK_ANIMATION := &"Unarmed_Melee_Attack_Punch_A"
const DEATH_ANIMATION := &"Death_A"
const GENERAL_ANIMATION_SOURCE := preload("res://assets/third_party/KayKit_Character_Animations_1.1/Animations/gltf/Rig_Medium/Rig_Medium_General.glb")
const ATTACK_ANIMATION_SOURCE := preload("res://assets/third_party/KayKit_Character_Animations_1.1/Animations/gltf/Rig_Medium/Rig_Medium_CombatMelee.glb")

@export var max_health: int = 100
@export var attack_range: float = 2.0
@export var attack_cooldown: float = 1.5
@export var telegraph_duration: float = 0.45
@export var attack_damage: int = 20
@export var respawn_delay: float = 2.0
@export_range(0.0, 1.0, 0.01) var enemy_hit_start: float = 0.30
@export_range(0.0, 1.0, 0.01) var enemy_hit_end: float = 0.60
@export_range(0.06, 0.10, 0.01) var hit_flash_duration: float = 0.08

@onready var health_label: Label3D = $Label3D
@onready var telegraph_label: Label3D = $TelegraphLabel
@onready var target_character: Node3D = $VisualRoot/TargetCharacter
@onready var target_animation_player: AnimationPlayer = $VisualRoot/TargetAnimationPlayer
@onready var enemy_attack_hitbox: Area3D = $VisualRoot/TargetCharacter/Rig_Medium/Skeleton3D/EnemyHandAttachment/EnemyAttackHitbox
@onready var player: CharacterBody3D = $"../Player"
@onready var static_collision: CollisionShape3D = $StaticBody3D/CollisionShape3D
@onready var hurtbox: Area3D = $Hurtbox

var current_health: int
var _enemy_attack_duration := 0.0
var _enemy_attack_elapsed := 0.0
var _telegraph_elapsed := 0.0
var _cooldown_remaining := 0.0
var _is_telegraphing := false
var _is_enemy_attacking := false
var _is_dead := false
var _death_animation_finished := false
var _death_started_at_msec := 0
var _initial_global_transform: Transform3D
var _enemy_hit_target_ids: Dictionary = {}
var _flash_material: StandardMaterial3D
var _flash_meshes: Array[MeshInstance3D] = []
var _original_material_overrides: Dictionary = {}
var _flash_generation := 0


func _ready() -> void:
	_initial_global_transform = global_transform
	current_health = max_health
	_update_health_label()
	_setup_target_animations()
	_setup_hit_flash()
	target_animation_player.animation_finished.connect(_on_target_animation_finished)
	_play_idle()


func _physics_process(delta: float) -> void:
	if _is_dead:
		_try_respawn()
		return

	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)

	if _is_enemy_attacking:
		_process_enemy_attack_hits(delta)
		return

	if _is_telegraphing:
		if not _player_can_be_attacked() or not _is_player_in_range():
			_cancel_telegraph()
			return
		_telegraph_elapsed += delta
		if _telegraph_elapsed >= telegraph_duration:
			_start_enemy_attack()
		return

	if _cooldown_remaining <= 0.0 and _player_can_be_attacked() and _is_player_in_range():
		_start_telegraph()


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
	_telegraph_elapsed = 0.0
	_enemy_attack_elapsed = 0.0
	_cooldown_remaining = 0.0
	_enemy_hit_target_ids.clear()
	telegraph_label.visible = false
	enemy_attack_hitbox.set_deferred("monitoring", false)
	target_animation_player.play(DEATH_ANIMATION)


func _finish_death_animation() -> void:
	_death_animation_finished = true
	static_collision.set_deferred("disabled", true)
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
	current_health = max_health
	_is_dead = false
	_death_animation_finished = false
	_is_telegraphing = false
	_is_enemy_attacking = false
	_telegraph_elapsed = 0.0
	_enemy_attack_elapsed = 0.0
	_cooldown_remaining = 0.0
	_enemy_hit_target_ids.clear()
	telegraph_label.visible = false
	static_collision.set_deferred("disabled", false)
	hurtbox.set_deferred("monitoring", true)
	hurtbox.set_deferred("monitorable", true)
	enemy_attack_hitbox.set_deferred("monitoring", true)
	_update_health_label()
	_play_idle()


func _setup_target_animations() -> void:
	var general_source := GENERAL_ANIMATION_SOURCE.instantiate()
	var general_player := general_source.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var general_library := general_player.get_animation_library(&"")
	var target_library := general_library.duplicate(true) as AnimationLibrary

	var attack_source := ATTACK_ANIMATION_SOURCE.instantiate()
	var attack_player := attack_source.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var attack_animation := attack_player.get_animation("Melee_Unarmed_Attack_Punch_A").duplicate(true) as Animation
	target_library.add_animation(ENEMY_ATTACK_ANIMATION, attack_animation)
	_enemy_attack_duration = attack_animation.length

	target_animation_player.add_animation_library(&"", target_library)
	general_source.free()
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
	_is_telegraphing = true
	_telegraph_elapsed = 0.0
	telegraph_label.visible = true
	_play_idle()


func _cancel_telegraph() -> void:
	_is_telegraphing = false
	_telegraph_elapsed = 0.0
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
	target_animation_player.play(ENEMY_ATTACK_ANIMATION)


func _finish_enemy_attack() -> void:
	_is_enemy_attacking = false
	_enemy_attack_elapsed = 0.0
	_cooldown_remaining = attack_cooldown
	_play_idle()


func _process_enemy_attack_hits(delta: float) -> void:
	if _is_dead:
		return
	_enemy_attack_elapsed += delta
	if _enemy_attack_duration <= 0.0:
		return

	var normalized_progress := _enemy_attack_elapsed / _enemy_attack_duration
	if normalized_progress < enemy_hit_start or normalized_progress > enemy_hit_end:
		return

	for hurtbox in enemy_attack_hitbox.get_overlapping_areas():
		var target := hurtbox.get_parent()
		if target != player or not target.has_method("take_damage"):
			continue
		var target_id := target.get_instance_id()
		if _enemy_hit_target_ids.has(target_id):
			continue
		_enemy_hit_target_ids[target_id] = true
		target.take_damage(attack_damage, enemy_attack_hitbox.global_position)


func _player_can_be_attacked() -> bool:
	return is_instance_valid(player) and int(player.get("current_health")) > 0


func _is_player_in_range() -> bool:
	return global_position.distance_to(player.global_position) <= attack_range


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
	target_animation_player.play(IDLE_ANIMATION)


func _on_target_animation_finished(animation_name: StringName) -> void:
	if animation_name == DEATH_ANIMATION and _is_dead:
		_finish_death_animation()
	elif animation_name == ENEMY_ATTACK_ANIMATION and _is_enemy_attacking:
		_finish_enemy_attack()
	elif animation_name == HIT_REACTION_ANIMATION:
		_play_idle()
	elif animation_name == IDLE_ANIMATION and not _is_enemy_attacking:
		_play_idle()


func _update_health_label() -> void:
	health_label.text = "%d HP" % current_health
