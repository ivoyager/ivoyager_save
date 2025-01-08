# save.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2017-2025 Charlie Whitfield
# I, Voyager is a registered trademark of Charlie Whitfield in the US
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************************
extends Node

## Singleton that provides API for saving and loading.
##
## This node is added as singleton "IVSave".[br][br]

signal save_started()
signal save_finished()
signal load_started()
signal about_to_free_procedural_tree_for_load()
signal about_to_build_procedural_tree_for_load()
signal load_finished()

signal status_changed(is_saving: bool, is_loading: bool)

signal dialog_opened(control: Control) # emitted by the dialog
signal dialog_closed(control: Control) # emitted by the dialog

signal save_dialog_requested()
signal load_dialog_requested()
signal close_dialogs_requested()


enum SaveType {
	NAMED_SAVE,
	QUICKSAVE,
	AUTOSAVE,
}

## Prints procedural node accounting at save and after load. 
const DEBUG_PRINT_NODES := false
## Frames delay after load (in case procedural nodes build additional nodes).
const DEBUG_PRINT_NODES_DELAY := 60

var is_saving: bool
var is_loading: bool

## TODO: Replace save_root
## Root node(s) for save and load. If empty, class methods use the current scene
## root obtained by [code]get_tree().get_current_scene()[/code].
## Root nodes must have
## [code]const PERSIST_MODE := IVSaveUtils.PersistMode.PERSIST_PROPERTIES_ONLY[/code].
## Descendant nodes may have value [code]PERSIST_PROCEDURAL[/code] (see comments in IVTreeSaver).
var save_roots: Array[NodePath] = []


## TODO: Replace w/ save_roots
## Root node for saving and loading. If null, class methods use
## get_tree().get_current_scene().
var save_root: Node = null

var directory_cache_path := "user://cache/saves_dir.ivbinary"
var fallback_directory := "user://saves"
var autosave_subdirectory := "autosaves"
var autosave_name := "AutoSave_"
var autosave_number := 10
var add_suffix_to_autosave := false ## If false, appends an integer suffix.
var quicksave_name := "QuickSave"
var add_suffix_to_quicksave := false ## If false, there will be only one file that is overwritten.
var file_extension := "GameSave"
var file_description := "Game Save"

## Callable that supplies the base name for the save file.
var name_generator := func() -> String:
	return "Save"
## Callable that supplies a suffix for the save file name. Placeholder method
## supplies a modified date-time string from the operating system in the form:
## "_YYYY-MM-DD_HH.MM.SS".
var suffix_generator := func() -> String:
	return "_" + Time.get_datetime_string_from_system().replace("T", "_").replace(":", ".")
## Allows uncompleted processes to finish. Use in conjuction with
## [member save_checkpoint] to ensure that game state is stable before
## persisted data is read for save.
var save_frames_delay := 5
## Allows uncompleted processes to finish. Use in conjuction with
## [member load_checkpoint] to ensure that game state is stable before
## deconstruction of the existing procedural tree begins.
var load_deconstruction_frames_delay := 5
## Delay occurs after exising procedural nodes have been freed but before
## the loaded procedural tree is added. Can prevent hard-to-debug issues that
## result from freeing nodes responding to signals before they are fully
## destroyed. 
var load_reconstruction_frames_delay := 5
## Method must return true or false. If false, a save is not attempted.
var save_permission_test := func() -> bool: return true
## Method must return true or false. If false, a load is not attempted.
var load_permission_test := func() -> bool: return true
## Method (possibly a coroutine) awaited before save is started. Must return
## true or false; if false, the save is aborted. Use in conjuction with
## [member save_frames_delay] to ensure that game state is stable (threads
## finished, etc.) before save starts.
var save_checkpoint := func() -> bool: return true
## Method (possibly a coroutine) awaited before load is started. Must return
## true or false; if false, the load is aborted. Use in conjuction with
## [member load_deconstruction_frames_delay] to ensure that game state is
## stable (threads finished, etc.) before load starts.
var load_checkpoint := func() -> bool: return true


var _directory: String # globalized path
var _autosave_integer := 1

@onready var _tree_saver := IVTreeSaver.new()



func _ready() -> void:
	# Make sure we have a directory and a place to cache user directory change.
	var dir_cache := FileAccess.open(directory_cache_path, FileAccess.READ)
	if !dir_cache:
		DirAccess.make_dir_recursive_absolute(directory_cache_path.get_base_dir())
	else:
		var directory: String = dir_cache.get_var()
		if DirAccess.dir_exists_absolute(directory):
			_directory = directory
	if !_directory:
		_directory = ProjectSettings.globalize_path(fallback_directory)
		DirAccess.make_dir_recursive_absolute(_directory)


func get_file_name(save_type := SaveType.NAMED_SAVE) -> String:
	var base_name: String
	match save_type:
		SaveType.NAMED_SAVE:
			base_name = name_generator.call() + suffix_generator.call()
		SaveType.QUICKSAVE:
			base_name = quicksave_name
			if add_suffix_to_quicksave:
				base_name += suffix_generator.call()
		SaveType.AUTOSAVE:
			base_name = autosave_name
			if add_suffix_to_quicksave:
				base_name += suffix_generator.call()
			else:
				base_name += str(_autosave_integer)
	return base_name + "." + file_extension


func get_file_path(save_type := SaveType.NAMED_SAVE) -> String:
	if save_type != SaveType.AUTOSAVE:
		return get_directory().path_join(get_file_name(save_type))
	return get_directory().path_join(autosave_subdirectory).path_join(get_file_name(save_type))


func get_directory() -> String:
	return _directory


## Will set the parent directory if [param path] points to the autosave
## subdirectory. Expects globalized path.
func set_directory(dir_path: String) -> void:
	if dir_path.get_file() == autosave_subdirectory:
		dir_path = dir_path.get_base_dir()
	if dir_path == _directory:
		return
	var dir_cache := FileAccess.open(directory_cache_path, FileAccess.WRITE)
	if !dir_cache:
		push_error("Failed to open cache file for write at " + directory_cache_path)
		return
	dir_cache.store_var(dir_path)
	_directory = dir_path


## File name is constructed according to "quicksave" class properties.
func quicksave() -> void:
	save_file(SaveType.QUICKSAVE)


## File name is constructed according to "autosave" class properties.
func autosave() -> void:
	save_file(SaveType.AUTOSAVE)


## Load the last modified file at the cached directory (or its subdirectories),
## or request load dialog if there are none.
func quickload() -> void:
	load_file(true)


## Use default args to request save dialog. [param path] is used only if
## [code]save_type == SaveType.NAMED_SAVE[/code].
func save_file(save_type := SaveType.NAMED_SAVE, path := "") -> void:
	if is_loading or !save_permission_test.call():
		return
	if save_type != SaveType.NAMED_SAVE:
		path = get_file_path(save_type)
	if !path:
		save_dialog_requested.emit()
		return
	is_saving = true
	status_changed.emit(true, false)
	var await_result: bool = await save_checkpoint.call()
	if await_result == false:
		is_saving = false
		status_changed.emit(false, false)
		return
	print("Saving " + path)
	save_started.emit()
	for i in save_frames_delay:
		await get_tree().process_frame
	var root := save_root if save_root else get_tree().get_current_scene()
	if DEBUG_PRINT_NODES:
		IVSaveUtils.print_debug_log(root, false)
	var save_data: Array = _tree_saver.get_gamesave(root)
	_store_data_to_file(save_data, path)
	save_finished.emit()
	is_saving = false
	status_changed.emit(false, false)


## Use default args to request load dialog. If [code]load_last == true[/code],
## then [param path] will be ignored.
func load_file(load_last := false, path := "") -> void:
	if is_saving or !load_permission_test.call():
		return
	if load_last:
		path = get_last_modified_file_path(get_directory()) # "" if no files found
	if !path:
		load_dialog_requested.emit()
		return
	if !FileAccess.file_exists(path):
		push_error("Could not find file for load: " + path)
		return
	is_loading = true
	status_changed.emit(false, true)
	var await_result: bool = await load_checkpoint.call()
	if await_result == false:
		is_loading = false
		status_changed.emit(false, false)
		return
	print("Loading " + path)
	load_started.emit()
	for i in load_deconstruction_frames_delay:
		await get_tree().process_frame
	about_to_free_procedural_tree_for_load.emit()
	var root := save_root if save_root else get_tree().get_current_scene()
	IVSaveUtils.free_procedural_objects_recursive(root)
	var save_data := _get_data_from_file(path)
	for i in load_reconstruction_frames_delay:
		await get_tree().process_frame
	about_to_build_procedural_tree_for_load.emit()
	_tree_saver.build_attached_tree(save_data, root)
	load_finished.emit()
	is_loading = false
	status_changed.emit(false, false)
	if DEBUG_PRINT_NODES:
		for i in DEBUG_PRINT_NODES_DELAY:
			await get_tree().process_frame
		IVSaveUtils.print_debug_log(root, true)
	

func has_file_for_load(path: String, search_subdirectories := true) -> bool:
	var dir := DirAccess.open(path)
	if !dir:
		return false
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name:
		if !dir.current_is_dir():
			if file_name.get_extension() == file_extension:
				return true
		elif search_subdirectories:
			if has_file_for_load(path.path_join(file_name), true):
				return true
		file_name = dir.get_next()
	return false


func close_dialogs() -> void:
	close_dialogs_requested.emit()


## The search includes subdirectories.
func get_last_modified_file_path(dir_path: String) -> String:
	var path_time_result := ["", 0]
	_get_last_modified_recursive(dir_path, path_time_result)
	return path_time_result[0]


func _get_last_modified_recursive(dir_path: String, path_time_result: Array) -> void:
	# Searches subdirectories recursively
	var dir := DirAccess.open(dir_path)
	if !dir:
		return
	dir.list_dir_begin()
	var next_name := dir.get_next()
	while next_name:
		if !dir.current_is_dir():
			if next_name.get_extension() == file_extension:
				var file_path := dir_path.path_join(next_name)
				var time := FileAccess.get_modified_time(file_path)
				if time > path_time_result[1]:
					path_time_result[0] = file_path
					path_time_result[1] = time
		else:
			_get_last_modified_recursive(dir_path.path_join(next_name), path_time_result)
		next_name = dir.get_next()


func _store_data_to_file(save_data: Array, path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	var err := FileAccess.get_open_error()
	if err != OK:
		return false
	file.store_var(save_data)
	return true


func _get_data_from_file(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	var err := FileAccess.get_open_error()
	if err != OK:
		return []
	return file.get_var()
