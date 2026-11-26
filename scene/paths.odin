package scene

// Paths in a level are relative to the level file and use forward slashes, so
// levels, captures and models can move together and between machines.

import "core:os"
import "core:fmt"
import "core:slice"
import "core:path/filepath"
import "core:strings"

// The folder a level file is in ("." for a bare file name).
level_dir :: proc(level_path: string) -> string {
	d := filepath.dir(level_path)
	return d if len(d) > 0 else "."
}

// `target` (relative to the working directory, or absolute) as the level file
// would write it: relative to the level's folder, forward slashes. If the two
// cannot be related (another drive), the absolute path.
//
// Lexical: the level file may not exist yet, and filepath.abs needs it to.
relative :: proc(level_path, target: string, allocator := context.allocator) -> string {
	context.allocator = context.temp_allocator
	cwd, _ := os.get_working_directory(context.temp_allocator)
	base := absolute(cwd, level_dir(level_path))
	abs_target := absolute(cwd, target)
	rel, rerr := filepath.rel(base, abs_target)
	if rerr != .None do return slashes(abs_target, allocator)
	return slashes(rel, allocator)
}

// Whether two paths (relative to the working directory, or absolute) name the
// same file, lexically: "./a/b.spz" and "a/../a/b.spz" do.
same_path :: proc(a, b: string) -> bool {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return absolute(cwd, a) == absolute(cwd, b)
}

@(private)
absolute :: proc(cwd, p: string) -> string {
	if filepath.is_abs(p) || len(cwd) == 0 {
		c, _ := filepath.clean(p, context.temp_allocator)
		return c
	}
	j, _ := filepath.join({cwd, p}, context.temp_allocator)
	return j // join cleans
}

// A path read from a level file, as the program opens it: relative to the
// working directory, or absolute.
resolve :: proc(level_path, ref: string, allocator := context.allocator) -> string {
	if len(ref) == 0 do return strings.clone("", allocator)
	if filepath.is_abs(ref) do return strings.clone(ref, allocator)
	joined, _ := filepath.join({level_dir(level_path), ref}, context.temp_allocator)
	cleaned, _ := filepath.clean(joined, allocator)
	return cleaned
}

@(private)
slashes :: proc(p: string, allocator := context.allocator) -> string {
	s, _ := strings.replace_all(p, "\\", "/", allocator)
	return s
}

// The default level for a capture: levels/<capture name>/level.json, in the
// working directory, so levels sit with the project (in git) and not with the
// captures (often too big for it). A level's folder holds what is edited
// (level.json, mission.base.json) and build/, what the editor writes from it:
//
//   levels/krakow/
//     level.json              the level
//     mission.base.json       the designer's mission, merged into the export
//     level.autosave.json     unsaved changes at close (not in git)
//     build/
//       mission.json          ctrl+E: what commandos plays
//       map.json, map.bin     ctrl+E: the gameplay map
//       terrain.*             ctrl+E: the terrain export, for tools/mapgen_check (not in git)
default_level_path :: proc(cloud_path: string, allocator := context.allocator) -> string {
	name := filepath.stem(cloud_path)
	if len(name) == 0 do name = "level"
	return strings.concatenate({"levels/", name, "/", LEVEL_FILE}, allocator)
}

LEVEL_FILE :: "level.json"
BUILD_DIR  :: "build"

// A level's id when it has none: its file's name, or for levels/<name>/level.json
// its folder's.
level_id :: proc(level_path: string) -> string {
	p := slashes(level_path, context.temp_allocator)
	name := p
	if i := strings.last_index_byte(name, '/'); i >= 0 do name = name[i + 1:]
	if name == LEVEL_FILE {
		dir := p[:max(len(p) - len(name) - 1, 0)]
		if i := strings.last_index_byte(dir, '/'); i >= 0 do dir = dir[i + 1:]
		if len(dir) > 0 && dir != "." && dir != ".." do return dir
	}
	if i := strings.last_index_byte(name, '.'); i > 0 do name = name[:i]
	return name
}

// A file in the level's build folder, relative to the level: what the level
// file stores.
build_file :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s", BUILD_DIR, name)
}

// Where unsaved changes go when the window is closed: next to the level,
// never over it.
autosave_path :: proc(level_path: string, allocator := context.allocator) -> string {
	p := level_path
	if strings.has_suffix(p, ".json") do p = p[:len(p) - len(".json")]
	return strings.concatenate({p, ".autosave.json"}, allocator)
}

// The levels under root (levels/<name>/level.json), sorted by name, for the
// level picker. Allocated with allocator; an unreadable root gives none.
list_levels :: proc(root: string, allocator := context.allocator) -> []string {
	entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return nil
	found := make([dynamic]string, allocator)
	for e in entries {
		if e.type != .Directory do continue
		path := strings.concatenate({slashes(root, context.temp_allocator), "/", e.name, "/", LEVEL_FILE}, allocator)
		if os.exists(path) {
			append(&found, path)
		} else {
			delete(path, allocator)
		}
	}
	slice.sort(found[:])
	return found[:]
}
