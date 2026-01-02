# save_dialog.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2019-2026 Charlie Whitfield
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
class_name IVSaveDialog
extends FileDialog



func _ready() -> void:
	IVSave.save_configured.connect(_configure)


func _configure() -> void:
	add_filter("*." + IVSave.file_extension, IVSave.file_description)
	IVSave.save_dialog_requested.connect(_open)
	IVSave.close_dialogs_requested.connect(hide)
	file_selected.connect(_on_file_selected)
	visibility_changed.connect(_on_visibility_changed)


func _open() -> void:
	if visible:
		return
	popup_centered()
	current_path = IVSave.get_file_path()
	deselect_all()


func _on_file_selected(path: String) -> void:
	# Set parent directory if this is autosave directory. (This is more for
	# load, but here in case user manually saves to this directory for some reason.)
	var directory := current_dir
	if directory.get_file() == IVSave.autosave_subdirectory:
		directory = directory.get_base_dir()
	IVSave.set_directory(directory)
	IVSave.save_file(IVSave.SaveType.NAMED_SAVE, path)


func _on_visibility_changed() -> void:
	if visible:
		IVSave.dialog_opened.emit(self)
	else:
		IVSave.dialog_closed.emit(self)
