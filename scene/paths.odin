package scene

// Paths in a level are relative to the level file and use forward slashes, so
// levels, captures and models can move together and between machines.

import "core:os"
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

// The default level for a capture: levels/<capture name>.json, in the
// working directory, so levels sit with the project (in git) and not with the
// captures (often too big for it).
default_level_path :: proc(cloud_path: string, allocator := context.allocator) -> string {
	name := filepath.stem(cloud_path)
	if len(name) == 0 do name = "level"
	return strings.concatenate({"levels/", name, ".json"}, allocator)
}

// Where unsaved changes go when the window is closed: next to the level,
// never over it.
autosave_path :: proc(level_path: string, allocator := context.allocator) -> string {
	p := level_path
	if strings.has_suffix(p, ".json") do p = p[:len(p) - len(".json")]
	return strings.concatenate({p, ".autosave.json"}, allocator)
}
