package game

import testing "check"

INPUT_SLOT_COUNT :: 64
INPUT_SLOT_MASK  :: u64(INPUT_SLOT_COUNT - 1)
INPUT_PER_SLOT   :: 16
INPUT_SOURCES    :: 8
INPUT_DELAY_MAX  :: 32

#assert(INPUT_SLOT_COUNT & (INPUT_SLOT_COUNT - 1) == 0)

Command_Kind :: enum u8 {
	Noop,
	Spawn,
	Erase,
	Ignite,
	Explode,
	Dig,
	Move,
}

Input_Command :: struct {
	tick:     u64,
	seq:      u32,
	x:        i32,
	y:        i32,
	radius:   u16,
	material: u16,
	kind:     Command_Kind,
	source:   u8,
	buttons:  Player_Input,
	pressed:  Player_Input,
}

#assert(size_of(Input_Command) == 32)

Enqueue_Status :: enum u8 {
	Accepted,
	Late,
	Slot_Full,
	Too_Far,
	Bad_Source,
}

Input_Queue :: struct {
	slots:    [INPUT_SLOT_COUNT][INPUT_PER_SLOT]Input_Command,
	counts:   [INPUT_SLOT_COUNT]u8,
	next_seq: [INPUT_SOURCES]u32,
	delay:    u8,

	accepted: u64,
	late:     u64,
	rejected: u64,
	applied:  u64,
}

input_queue_init :: proc(q: ^Input_Queue, delay: u8) {
	q^ = {}
	q.delay = delay > INPUT_DELAY_MAX ? INPUT_DELAY_MAX : delay
}

input_queue_push :: proc(q: ^Input_Queue, now: u64, command: Input_Command, at_tick: i64 = -1) -> (out: Input_Command, status: Enqueue_Status) {
	out = command
	status = .Accepted

	if int(out.source) >= INPUT_SOURCES {
		q.rejected += 1
		return out, .Bad_Source
	}

	target := now + u64(q.delay)
	if at_tick >= 0 {
		target = u64(at_tick)
		if target < now {
			target = now
			status = .Late
		}
	}

	if target >= now + INPUT_SLOT_COUNT {
		q.rejected += 1
		return out, .Too_Far
	}

	slot := int(target & INPUT_SLOT_MASK)
	if int(q.counts[slot]) >= INPUT_PER_SLOT {
		q.rejected += 1
		return out, .Slot_Full
	}

	out.tick = target
	out.seq  = q.next_seq[out.source]
	q.next_seq[out.source] += 1

	q.slots[slot][q.counts[slot]] = out
	q.counts[slot] += 1
	q.accepted += 1
	if status == .Late do q.late += 1

	return out, status
}

input_queue_drain :: proc(q: ^Input_Queue, tick: u64, out: []Input_Command) -> int {
	slot := int(tick & INPUT_SLOT_MASK)
	count := int(q.counts[slot])
	q.counts[slot] = 0
	if count == 0 do return 0

	copy(out[:count], q.slots[slot][:count])

	for i in 1 ..< count {
		command := out[i]
		j := i - 1
		for j >= 0 && input_command_after(out[j], command) {
			out[j+1] = out[j]
			j -= 1
		}
		out[j+1] = command
	}

	q.applied += u64(count)
	return count
}

input_command_after :: proc(a, b: Input_Command) -> bool {
	if a.source != b.source do return a.source > b.source
	return a.seq > b.seq
}

input_queue_depth :: proc(q: ^Input_Queue) -> (pending: int) {
	for count in q.counts do pending += int(count)
	return pending
}

input_queue_peek :: proc(q: ^Input_Queue, tick: u64) -> []Input_Command {
	slot := int(tick & INPUT_SLOT_MASK)
	return q.slots[slot][:q.counts[slot]]
}

@(private = "file")
spawn_command :: proc(source: u8, x, y: i32) -> Input_Command {
	return Input_Command{kind = .Spawn, source = source, x = x, y = y, material = 1}
}

@(test)
test_input_delay_sets_the_execution_tick :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 3)

	out, status := input_queue_push(&q, 100, spawn_command(0, 1, 1))
	testing.expect(t, status == .Accepted)
	testing.expect(t, out.tick == 103, "delay 3 must place the command three ticks ahead")
	testing.expect(t, input_queue_depth(&q) == 1)
}

@(test)
test_drain_only_takes_the_named_tick :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 2)
	input_queue_push(&q, 10, spawn_command(0, 1, 1))

	buffer: [INPUT_PER_SLOT]Input_Command
	testing.expect(t, input_queue_drain(&q, 10, buffer[:]) == 0, "tick 10 must be empty")
	testing.expect(t, input_queue_drain(&q, 11, buffer[:]) == 0, "tick 11 must be empty")
	testing.expect(t, input_queue_drain(&q, 12, buffer[:]) == 1, "tick 12 must hold the command")
	testing.expect(t, input_queue_drain(&q, 12, buffer[:]) == 0, "a drained tick must be empty")
}

@(test)
test_drain_order_ignores_arrival_order :: proc(t: ^testing.T) {
	forward: Input_Queue
	reverse: Input_Queue
	input_queue_init(&forward, 0)
	input_queue_init(&reverse, 0)

	input_queue_push(&forward, 0, spawn_command(0, 1, 1))
	input_queue_push(&forward, 0, spawn_command(1, 2, 2))
	input_queue_push(&forward, 0, spawn_command(0, 3, 3))

	input_queue_push(&reverse, 0, spawn_command(1, 2, 2))
	input_queue_push(&reverse, 0, spawn_command(0, 1, 1))
	input_queue_push(&reverse, 0, spawn_command(0, 3, 3))

	a: [INPUT_PER_SLOT]Input_Command
	b: [INPUT_PER_SLOT]Input_Command
	na := input_queue_drain(&forward, 0, a[:])
	nb := input_queue_drain(&reverse, 0, b[:])

	testing.expect(t, na == 3 && nb == 3)
	for i in 0 ..< na {
		testing.expect(t, a[i].source == b[i].source, "sources must line up")
		testing.expect(t, a[i].x == b[i].x, "commands must line up")
	}
	testing.expect(t, a[0].source == 0 && a[1].source == 0 && a[2].source == 1, "source 0 must run first")
	testing.expect(t, a[0].seq < a[1].seq, "one sender keeps its own order")
}

@(test)
test_late_command_moves_to_the_next_tick :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 2)

	out, status := input_queue_push(&q, 50, spawn_command(0, 1, 1), 20)
	testing.expect(t, status == .Late, "a tick in the past must report Late")
	testing.expect(t, out.tick == 50, "a late command must run at the next tick")
	testing.expect(t, q.late == 1)
	testing.expect(t, q.accepted == 1, "a late command still counts as accepted")
}

@(test)
test_command_beyond_the_ring_is_rejected :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 2)

	_, status := input_queue_push(&q, 0, spawn_command(0, 1, 1), INPUT_SLOT_COUNT)
	testing.expect(t, status == .Too_Far, "the ring must reject a far tick")
	testing.expect(t, q.rejected == 1)
	testing.expect(t, input_queue_depth(&q) == 0)

	_, edge := input_queue_push(&q, 0, spawn_command(0, 1, 1), INPUT_SLOT_COUNT-1)
	testing.expect(t, edge == .Accepted, "the last tick of the ring must fit")
}

@(test)
test_full_slot_is_rejected_not_dropped_in_silence :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 0)

	for i in 0 ..< INPUT_PER_SLOT {
		_, status := input_queue_push(&q, 0, spawn_command(0, i32(i), 0))
		testing.expect(t, status == .Accepted)
	}
	_, status := input_queue_push(&q, 0, spawn_command(0, 99, 0))
	testing.expect(t, status == .Slot_Full, "an over-full tick must report the fault")
	testing.expect(t, q.rejected == 1)
}

@(test)
test_bad_source_is_rejected :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 0)

	_, status := input_queue_push(&q, 0, spawn_command(INPUT_SOURCES, 1, 1))
	testing.expect(t, status == .Bad_Source)
	testing.expect(t, input_queue_depth(&q) == 0)
}

@(test)
test_ring_reuses_a_slot_after_the_drain :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 0)
	buffer: [INPUT_PER_SLOT]Input_Command

	input_queue_push(&q, 0, spawn_command(0, 7, 7))
	testing.expect(t, input_queue_drain(&q, 0, buffer[:]) == 1)

	input_queue_push(&q, INPUT_SLOT_COUNT, spawn_command(0, 8, 8))
	count := input_queue_drain(&q, INPUT_SLOT_COUNT, buffer[:])
	testing.expect(t, count == 1, "the reused slot must hold only the new command")
	testing.expect(t, buffer[0].x == 8, "the old command must be gone")
}

@(test)
test_delay_is_capped :: proc(t: ^testing.T) {
	q: Input_Queue
	input_queue_init(&q, 200)
	testing.expect(t, q.delay == INPUT_DELAY_MAX, "the delay must stay inside the ring")
}
