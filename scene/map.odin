package scene

// The level's "map" section: how the gameplay map is built from the capture
// (docs/map_spec.md). The map files themselves are built from the level, the
// level stays the source of truth:
//
//   "map": {
//     "file": "krakow.map.json",   written by the export, next to the level
//     "cell": 1,                   metres
//     "yaw": 20,                   the frame's turn, degrees: measured on the
//                                  first build, then kept, so nothing typed in
//                                  map metres ever shifts
//     "edits": [                   applied in order on every rebuild, one per line
//       { "id": "e1", "kind": "Building", "target": "b:31,27", "walkableRoof": true },
//       { "id": "e2", "kind": "Link", "link": "Ladder", "a": [24, 9.2, 0], "b": [24, 11, 10] }
//     ]
//   }
//
// An edit writes only its id, kind and the fields it sets, so each is one
// short line in git.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

import "cmd:gamemap"

Map_Section :: struct {
	file:  string,
	cell:  f32,
	yaw:   Maybe(f32),
	edits: []gamemap.Edit,
}

MAP_DEFAULT_CELL :: f32(1)

map_cell :: proc(s: Map_Section) -> f32 {
	return s.cell if s.cell > 0 else MAP_DEFAULT_CELL
}

// One edit as a line of JSON: id and kind, then every field that is set, in
// the struct's order.
encode_edit :: proc(edit: gamemap.Edit, allocator := context.allocator) -> string {
	e := edit
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{ ")
	first := true
	for field in reflect.struct_fields_zipped(gamemap.Edit) {
		v := any{rawptr(uintptr(&e) + field.offset), field.type.id}
		if field.name != "id" && field.name != "kind" && is_unset(v) do continue
		name := field.name
		if tag, ok := reflect.struct_tag_lookup(field.tag, "json"); ok {
			if comma := strings.index_byte(tag, ','); comma >= 0 do name = tag[:comma]
			else do name = tag
		}
		text, ok := edit_value(v)
		if !ok do continue
		if !first do strings.write_string(&b, ", ")
		first = false
		fmt.sbprintf(&b, "%s: %s", quote(name), text)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// Numbers as the rest of the level writes them (shortest, no ".0"), the
// rest through json.marshal with enum names.
@(private)
edit_value :: proc(v: any) -> (string, bool) {
	switch x in v {
	case f32:
		return num(x), true
	case Maybe(f32):
		return num(x.? or_else 0), true
	case [2]f32:
		return fmt.tprintf("[%s, %s]", num(x.x), num(x.y)), true
	case [3]f32:
		return vec(x), true
	case [][2]f32:
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for p, i in x do fmt.sbprintf(&b, "%s[%s, %s]", ", " if i > 0 else "", num(p.x), num(p.y))
		strings.write_byte(&b, ']')
		return strings.to_string(b), true
	}
	text, err := json.marshal(v, {use_enum_names = true}, context.temp_allocator)
	return string(text), err == nil
}

// Zero bytes, an empty slice or string, or a nil Maybe.
@(private)
is_unset :: proc(v: any) -> bool {
	ti := runtime.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Slice:
		return (^runtime.Raw_Slice)(v.data).len == 0
	case runtime.Type_Info_String:
		return len((^string)(v.data)^) == 0
	case runtime.Type_Info_Union:
		return reflect.is_nil(v)
	}
	return mem.check_zero(([^]byte)(v.data)[:ti.size])
}

encode_map_section :: proc(b: ^strings.Builder, s: Map_Section) {
	fmt.sbprintf(b, "  \"map\": {{\n    \"file\": %s,\n    \"cell\": %s,\n", quote(s.file), num(map_cell(s)))
	if y, has := s.yaw.?; has do fmt.sbprintf(b, "    \"yaw\": %s,\n", num(y))
	strings.write_string(b, "    \"edits\": [")
	for e, i in s.edits {
		strings.write_string(b, "\n      " if i == 0 else ",\n      ")
		strings.write_string(b, encode_edit(e, context.temp_allocator))
	}
	strings.write_string(b, "\n    ]\n  },\n" if len(s.edits) > 0 else "]\n  },\n")
}

// Repairs after reading: an edit without an id, or with one taken, gets a
// fresh one ("e<n>"). Warnings in the temp allocator.
check_map_section :: proc(s: ^Map_Section, warn: ^[dynamic]string, allocator := context.allocator) {
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for e in s.edits do if e.id != "" do seen[e.id] = false
	n := 1
	for &e in s.edits {
		if e.id != "" && !seen[e.id] {
			seen[e.id] = true
			continue
		}
		old := e.id
		for (fmt.tprintf("e%d", n) in seen) do n += 1
		fresh := fmt.tprintf("e%d", n)
		seen[strings.clone(fresh, context.temp_allocator)] = true
		append(warn, fmt.tprintf("map edit %q: id taken or missing, now %s", old, fresh))
		delete(e.id, allocator)
		e.id = strings.clone(fresh, allocator)
	}
}

clone_map_section :: proc(s: Map_Section, allocator := context.allocator) -> Map_Section {
	out := s
	out.file = strings.clone(s.file, allocator)
	out.edits = make([]gamemap.Edit, len(s.edits), allocator)
	for e, i in s.edits {
		c := e
		c.id = strings.clone(e.id, allocator)
		c.target = strings.clone(e.target, allocator)
		c.region = clone_points(e.region, allocator)
		c.footprint = clone_points(e.footprint, allocator)
		out.edits[i] = c
	}
	return out
}

destroy_map_section :: proc(s: ^Map_Section, allocator := context.allocator) {
	delete(s.file, allocator)
	for e in s.edits {
		delete(e.id, allocator)
		delete(e.target, allocator)
		delete(e.region, allocator)
		delete(e.footprint, allocator)
	}
	delete(s.edits, allocator)
	s^ = {}
}

@(private)
clone_points :: proc(p: [][2]f32, allocator := context.allocator) -> [][2]f32 {
	if len(p) == 0 do return nil
	out := make([][2]f32, len(p), allocator)
	copy(out, p)
	return out
}
