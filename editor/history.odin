package editor

// Undo / redo: snapshots of the level's objects (and the selection), taken
// before each change.
//
// The editor takes them itself where it changes the level: a placed object
// (commit in Place), a move put down (commit in Move: the snapshot has the
// object where it was picked up), a delete. Keyboard edits of an object are
// the caller's: it calls checkpoint before applying one (once per key press,
// so holding a key for a second is one step).
//
// Not undone, on purpose: ids (an undone object's id is not handed out again,
// ids stay stable), the world scale (a calibration, not an edit), the camera.
// A level loaded or reset starts a fresh history.

HISTORY_MAX :: 200 // steps kept; the oldest go first

Snapshot :: struct {
	instances: []Instance,
	selected:  u64,
}

History :: struct {
	undo: [dynamic]Snapshot,
	redo: [dynamic]Snapshot,
}

@(private)
snapshot_take :: proc(e: ^Editor) -> Snapshot {
	s := Snapshot{instances = make([]Instance, len(e.instances)), selected = e.selected}
	copy(s.instances, e.instances[:])
	return s
}

@(private)
snapshot_free :: proc(s: ^Snapshot) {
	delete(s.instances)
	s^ = {}
}

@(private)
snapshot_same :: proc(a: Snapshot, e: ^Editor) -> bool {
	if len(a.instances) != len(e.instances) do return false
	for inst, i in a.instances {
		if inst != e.instances[i] do return false
	}
	return true
}

@(private)
snapshot_restore :: proc(e: ^Editor, s: Snapshot) {
	resize(&e.instances, len(s.instances))
	copy(e.instances[:], s.instances)
	e.selected = s.selected
	if inst, _ := find(e, e.selected); inst == nil do e.selected = 0
}

@(private)
history_clear :: proc(list: ^[dynamic]Snapshot) {
	for &s in list do snapshot_free(&s)
	clear(list)
}

history_destroy :: proc(h: ^History) {
	history_clear(&h.undo)
	history_clear(&h.redo)
	delete(h.undo)
	delete(h.redo)
	h^ = {}
}

history_reset :: proc(h: ^History) {
	history_clear(&h.undo)
	history_clear(&h.redo)
}

@(private)
push_undo :: proc(e: ^Editor, s: Snapshot) {
	h := &e.history
	if len(h.undo) >= HISTORY_MAX {
		snapshot_free(&h.undo[0])
		ordered_remove(&h.undo, 0)
	}
	append(&h.undo, s)
	history_clear(&h.redo) // a new change: the undone steps are gone
}

// The level as it is now becomes an undo step: call before changing it.
// Nothing is recorded if it is the same as the last step.
checkpoint :: proc(e: ^Editor) {
	h := &e.history
	if len(h.undo) > 0 && snapshot_same(h.undo[len(h.undo) - 1], e) {
		if len(h.redo) > 0 do history_clear(&h.redo)
		return
	}
	push_undo(e, snapshot_take(e))
}

// A move put down: the step to undo is the object where it was picked up.
@(private)
checkpoint_move :: proc(e: ^Editor) {
	s := snapshot_take(e)
	for &inst in s.instances {
		if inst.id == e.backup.id do inst = e.backup
	}
	push_undo(e, s)
}

can_undo :: proc(e: ^Editor) -> int {return len(e.history.undo)}
can_redo :: proc(e: ^Editor) -> int {return len(e.history.redo)}

// Back one step. While moving, undo is Esc: the object goes back. While
// placing, the placing goes on (undo takes back the last one stamped).
// false: nothing to undo.
undo :: proc(e: ^Editor) -> bool {
	if e.mode == .Move {
		cancel(e)
		return true
	}
	h := &e.history
	if len(h.undo) == 0 do return false
	append(&h.redo, snapshot_take(e))
	s := pop(&h.undo)
	snapshot_restore(e, s)
	snapshot_free(&s)
	return true
}

redo :: proc(e: ^Editor) -> bool {
	if e.mode == .Move do cancel(e)
	h := &e.history
	if len(h.redo) == 0 do return false
	append(&h.undo, snapshot_take(e))
	s := pop(&h.redo)
	snapshot_restore(e, s)
	snapshot_free(&s)
	return true
}
