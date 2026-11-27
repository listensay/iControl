//! Captured FPS input, driven exclusively by caller-supplied monotonic seconds.
//! An outer empty vector means no change; an inner empty vector lifts all fingers.

use std::collections::{BTreeMap, BTreeSet};

#[path = "joystick.rs"]
mod joystick;
use self::joystick::Joystick;

const TICK: f64 = 1.0 / 120.0;
const TAP: f64 = 0.070;
const LOOK_IDLE: f64 = 0.150;
// Allow the lift, center down and first drag across a rebase, but don't turn a
// delayed timer delivery into fresh motion. Never renew this on a timer tick.
const MOTION_FRESH: f64 = 3.0 * TICK;
const CONTACT_LIMIT: usize = 10;
const LAST_ID: u8 = 16;
const CURSOR_ACTION: u16 = u16::MAX;
const HOLD: u8 = 0;
const TAP_BUTTON: u8 = 1;
const SWIPE: u8 = 2;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    fn valid(self) -> bool {
        (0.0..=1.0).contains(&self.x) && (0.0..=1.0).contains(&self.y)
    }
    fn lerp(self, to: Self, fraction: f64) -> Self {
        Point {
            x: self.x + (to.x - self.x) * fraction,
            y: self.y + (to.y - self.y) * fraction,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Contact {
    pub id: u8,
    pub point: Point,
}

#[derive(Clone, Debug)]
pub struct Button {
    pub trigger: u16,
    pub behavior: u8,
    pub point: Point,
    pub end: Point,
    pub duration: f64,
    /// Zero for a custom button; preset IDs are in 3..=16.
    pub preferred: u8,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub aspect: f64,
    pub joystick: Point,
    pub joystick_radius: f64,
    pub joystick_enabled: bool,
    pub turn_duration: f64,
    pub smooth: bool,
    pub look: Point,
    pub look_width: f64,
    pub look_height: f64,
    pub look_enabled: bool,
    pub sensitivity: f64,
    pub swap_axes: bool,
    pub invert_x: bool,
    pub invert_y: bool,
    /// Low two bits: Swift rotation 0..3. Bit 2: mirror X; bit 3: mirror Y.
    pub mapping: u8,
    pub buttons: Vec<Button>,
    /// Already transitively expanded by the profile, in addition to each source itself.
    pub links: Vec<(u16, u16)>,
}

#[derive(Clone, Copy, Default)]
struct Swipe {
    start: Option<f64>,
    lift: Option<f64>,
}

#[derive(Clone, Copy, Default)]
struct ButtonState {
    tap_until: Option<f64>,
    swipe: Option<Swipe>,
    lease: Option<u8>,
}

#[derive(Clone, Copy)]
struct Motion {
    delta: Point,
    sampled: f64,
}

impl Motion {
    fn fresh(self, now: f64) -> bool {
        now - self.sampled <= MOTION_FRESH
    }
}

fn mouse_key(key: u16) -> bool {
    // Left/right/middle/back/forward, in FPSKey.choices order.
    (4..=8).contains(&key)
}

#[derive(Clone)]
pub struct Engine {
    config: Config,
    offset: Point,
    cursor: bool,
    physical: BTreeSet<u16>,
    owners: BTreeMap<u16, BTreeSet<u16>>,
    linked: BTreeMap<u16, Vec<u16>>,
    movement: Vec<u16>,
    release_deadline: Option<f64>,
    stick: Joystick,
    buttons: Vec<ButtonState>,
    pointer: Option<Point>,
    look: Option<Point>,
    pending: Option<Motion>,
    deferred: Option<Motion>,
    last_mouse: Option<f64>,
    last_look_tick: Option<f64>,
    previous: Vec<Contact>,
    scratch: Vec<Contact>,
}

impl Engine {
    pub fn new(mut config: Config) -> Self {
        if !(0.4..=3.0).contains(&config.aspect) {
            config.aspect = 4.0 / 3.0;
        }
        let mut linked = BTreeMap::<u16, Vec<u16>>::new();
        for (source, target) in config.links.drain(..) {
            if target == CURSOR_ACTION || source == target {
                continue;
            }
            let targets = linked.entry(source).or_default();
            if !targets.contains(&target) {
                targets.push(target);
            }
        }
        Self {
            buttons: vec![ButtonState::default(); config.buttons.len()],
            config,
            linked,
            offset: Point::default(),
            cursor: false,
            physical: BTreeSet::new(),
            owners: BTreeMap::new(),
            movement: Vec::with_capacity(4),
            release_deadline: None,
            stick: Joystick::default(),
            pointer: None,
            look: None,
            pending: None,
            deferred: None,
            last_mouse: None,
            last_look_tick: None,
            previous: Vec::with_capacity(CONTACT_LIMIT),
            scratch: Vec::with_capacity(CONTACT_LIMIT),
        }
    }

    pub fn set_aspect(&mut self, aspect: f64) {
        if (0.4..=3.0).contains(&aspect) {
            self.config.aspect = aspect;
        }
    }

    /// Profile offsets are continuous and cannot be encoded in the mapping bits.
    pub fn set_offset(&mut self, x: f64, y: f64) {
        if (-0.25..=0.25).contains(&x) && (-0.25..=0.25).contains(&y) {
            self.offset = Point { x, y };
        }
    }

    pub fn mapped(&self, point: Point) -> Point {
        let x = (point.x + self.offset.x).clamp(0.0, 1.0);
        let y = (point.y + self.offset.y).clamp(0.0, 1.0);
        let (mut x, mut y) = match self.config.mapping & 3 {
            1 => (y, 1.0 - x),
            2 => (1.0 - x, 1.0 - y),
            3 => (1.0 - y, x),
            _ => (x, y),
        };
        if self.config.mapping & 4 != 0 {
            x = 1.0 - x;
        }
        if self.config.mapping & 8 != 0 {
            y = 1.0 - y;
        }
        Point { x, y }
    }

    pub fn key(&mut self, key: u16, down: bool, now: f64) -> Vec<Vec<Contact>> {
        let mut frames = Vec::new();
        if key == CURSOR_ACTION {
            return frames;
        }
        if down {
            if (self.cursor && mouse_key(key)) || !self.physical.insert(key) {
                return frames;
            }
            // Swift postpones an all-up to the next tick. If a new movement
            // press beats that tick, deliver the lift *before* its center down.
            if key < 4 && self.movement.is_empty() && self.stick.direction().is_some() {
                self.emit(now, &mut frames);
            }
            let mut activated = BTreeSet::new();
            for logical in std::iter::once(&key).chain(self.linked.get(&key).into_iter().flatten())
            {
                let owners = self.owners.entry(*logical).or_default();
                if owners.is_empty() {
                    activated.insert(*logical);
                }
                owners.insert(key);
            }
            if key < 4 && activated.contains(&key) {
                self.movement.push(key);
                self.release_deadline = None;
            }
            // All re-triggered taps lift together, as in the Swift key-down path.
            let mut lift = false;
            for (button, state) in self.config.buttons.iter().zip(&mut self.buttons) {
                if button.behavior == TAP_BUTTON && activated.contains(&button.trigger) {
                    lift |= state.tap_until.take().is_some();
                }
            }
            if lift {
                self.emit(now, &mut frames);
            }
            for (button, state) in self.config.buttons.iter().zip(&mut self.buttons) {
                if button.behavior == TAP_BUTTON && activated.contains(&button.trigger) {
                    state.tap_until = Some(now + TAP);
                }
            }
            for i in 0..self.buttons.len() {
                let button = &self.config.buttons[i];
                if button.behavior == SWIPE && activated.contains(&button.trigger) {
                    if self.buttons[i].swipe.take().is_some() {
                        self.emit(now, &mut frames);
                    }
                    self.buttons[i].swipe = Some(Swipe::default());
                }
            }
        } else {
            if !self.physical.remove(&key) {
                return frames;
            }
            let mut released = BTreeSet::new();
            self.owners.retain(|logical, owners| {
                owners.remove(&key);
                if owners.is_empty() {
                    released.insert(*logical);
                }
                !owners.is_empty()
            });
            if released.is_empty() {
                return frames;
            }
            if released.iter().any(|&k| k < 4) {
                self.movement.retain(|k| !released.contains(k));
                if self.movement.is_empty() {
                    self.release_deadline = None;
                    if released.iter().all(|&k| k < 4) {
                        return frames;
                    }
                } else if self.release_deadline.is_none() {
                    self.stick.freeze();
                    self.release_deadline = Some(now + TICK);
                }
            }
        }
        self.emit(now, &mut frames);
        frames
    }

    pub fn pulse(&mut self, index: usize, now: f64) -> Vec<Vec<Contact>> {
        let mut frames = Vec::new();
        let Some(button) = self.config.buttons.get(index) else {
            return frames;
        };
        if button.behavior == SWIPE {
            if self.buttons[index].swipe.take().is_some() {
                self.emit(now, &mut frames);
            }
            self.buttons[index].swipe = Some(Swipe::default());
        } else {
            if self.buttons[index].tap_until.take().is_some() {
                self.emit(now, &mut frames);
            }
            self.buttons[index].tap_until = Some(now + TAP);
        }
        self.emit(now, &mut frames);
        frames
    }

    pub fn set_cursor(&mut self, on: bool, now: f64) -> Vec<Vec<Contact>> {
        if self.cursor == on {
            return Vec::new();
        }
        self.cursor = on;
        self.pointer = None;
        self.look = None;
        self.pending = None;
        self.deferred = None;
        self.last_mouse = None;
        self.physical.retain(|&k| !mouse_key(k));
        self.owners.retain(|&k, owners| {
            owners.retain(|&source| !mouse_key(source));
            !mouse_key(k) && !owners.is_empty()
        });
        for (button, state) in self.config.buttons.iter().zip(&mut self.buttons) {
            if mouse_key(button.trigger) {
                state.tap_until = None;
                state.swipe = None;
            }
        }
        self.event_frame(now)
    }

    pub fn pointer_down(&mut self, point: Point, now: f64) -> Vec<Vec<Contact>> {
        if !self.cursor || self.pointer.is_some() || !point.valid() {
            return Vec::new();
        }
        self.pointer = Some(point);
        self.event_frame(now)
    }

    pub fn pointer_move(&mut self, point: Point) {
        if self.cursor && self.pointer.is_some() && point.valid() {
            self.pointer = Some(point);
        }
    }

    pub fn pointer_up(&mut self, now: f64) -> Vec<Vec<Contact>> {
        if self.pointer.is_none() {
            return Vec::new();
        }
        // Flush a final coalesced drag before the up snapshot.
        let mut frames = self.event_frame(now);
        self.pointer = None;
        self.emit(now, &mut frames);
        frames
    }

    pub fn mouse(&mut self, dx: f64, dy: f64, now: f64) {
        if self.cursor
            || !self.config.look_enabled
            || !dx.is_finite()
            || !dy.is_finite()
            || (dx == 0.0 && dy == 0.0)
        {
            return;
        }
        let (x, y) = if self.config.swap_axes {
            (dy, dx)
        } else {
            (dx, dy)
        };
        let factor = 0.0012 * self.config.sensitivity;
        let dx = (if self.config.invert_x { -x } else { x }) * factor;
        let dy = (if self.config.invert_y { -y } else { y }) * factor * self.config.aspect;
        // Sum before applying the per-tick travel cap: opposing large deltas
        // within one tick must cancel. Age the bucket from its first sample so
        // a stream of small events cannot keep a stalled aggregate fresh.
        let mut motion = self.pending.filter(|m| m.fresh(now)).unwrap_or(Motion {
            delta: Point::default(),
            sampled: now,
        });
        motion.delta.x = (motion.delta.x + dx).clamp(f64::MIN, f64::MAX);
        motion.delta.y = (motion.delta.y + dy).clamp(f64::MIN, f64::MAX);
        self.pending = Some(motion);
        self.last_mouse = Some(now);
    }

    pub fn advance(&mut self, now: f64) -> Vec<Vec<Contact>> {
        if self.last_look_tick != Some(now) {
            self.last_look_tick = Some(now);
            self.tick_look(now);
        }
        self.event_frame(now)
    }

    fn tick_look(&mut self, now: f64) {
        // Only timer ticks drain motion. Fresh input supersedes a deferred step
        // from the center-down/rebase handshake; there is no delta backlog.
        let motion = self
            .pending
            .take()
            .or(self.deferred.take())
            .filter(|m| m.fresh(now))
            .filter(|m| m.delta.x.abs() + m.delta.y.abs() > 0.000001);
        let Some(mut motion) = motion else {
            if self.last_mouse.map_or(true, |t| now - t > LOOK_IDLE) {
                self.look = None;
            }
            return;
        };
        let cap_x = 0.10_f64.min(self.config.look_width * 0.45);
        let cap_y = 0.10_f64.min(self.config.look_height * 0.45);
        motion.delta.x = motion.delta.x.clamp(-cap_x, cap_x);
        motion.delta.y = motion.delta.y.clamp(-cap_y, cap_y);
        let center = self.config.look;
        if let Some(p) = self.look {
            let next = Point {
                x: p.x + motion.delta.x,
                y: p.y + motion.delta.y,
            };
            let w = self.config.look_width / 2.0;
            let h = self.config.look_height / 2.0;
            if (center.x - w..=center.x + w).contains(&next.x)
                && (center.y - h..=center.y + h).contains(&next.y)
            {
                self.look = Some(next);
                return; // Even if capped, this entire aggregate is consumed.
            }
            self.look = None; // Boundary crossing: a full snapshot without finger 2.
        } else {
            self.look = Some(center);
        }
        self.deferred = Some(motion); // One bounded step, original sample timestamp.
    }

    fn event_frame(&mut self, now: f64) -> Vec<Vec<Contact>> {
        let mut frames = Vec::new();
        self.emit(now, &mut frames);
        frames
    }

    fn emit(&mut self, now: f64, frames: &mut Vec<Vec<Contact>>) {
        let cfg = &self.config;
        if let Some(deadline) = self.release_deadline {
            if now >= deadline {
                self.stick
                    .advance(&self.movement, deadline, cfg.turn_duration, cfg.smooth);
                self.release_deadline = None;
            }
        }
        if self.release_deadline.is_none() {
            self.stick
                .advance(&self.movement, now, cfg.turn_duration, cfg.smooth);
        }
        self.scratch.clear();
        if cfg.joystick_enabled {
            if let Some(dir) = self.stick.direction() {
                let point = Point {
                    x: (cfg.joystick.x + dir.x * cfg.joystick_radius / cfg.aspect)
                        .clamp(0.005, 0.995),
                    y: (cfg.joystick.y + dir.y * cfg.joystick_radius).clamp(0.005, 0.995),
                };
                self.scratch.push(Contact { id: 1, point });
            }
        }
        if let Some(point) = if self.cursor { self.pointer } else { self.look } {
            self.scratch.push(Contact { id: 2, point });
        }
        self.emit_buttons(now);
        for i in 0..self.scratch.len() {
            self.scratch[i].point = self.mapped(self.scratch[i].point);
        }
        // Contact order has no meaning on the wire (Swift encodes in ID order).
        self.scratch.sort_unstable_by_key(|contact| contact.id);
        if self.scratch != self.previous {
            frames.push(self.scratch.clone());
            std::mem::swap(&mut self.scratch, &mut self.previous);
        }
    }

    fn emit_buttons(&mut self, now: f64) {
        let mut unavailable = 0_u32;
        for state in &mut self.buttons {
            // Include prior leases even if about to be released: an identifier
            // must be absent from a snapshot before a different button uses it.
            if let Some(id) = state.lease {
                unavailable |= 1 << id;
            }
            if state.tap_until.is_some_and(|t| now >= t) {
                state.tap_until = None;
            }
            if state.swipe.and_then(|s| s.lift).is_some_and(|t| now >= t) {
                state.swipe = None;
            }
        }
        let mut slots = CONTACT_LIMIT - self.scratch.len();
        for retained in [true, false] {
            for (button, state) in self.config.buttons.iter().zip(&mut self.buttons) {
                if state.lease.is_some() != retained {
                    continue;
                }
                let active = state.swipe.is_some()
                    || state.tap_until.is_some()
                    || (button.behavior == HOLD && self.owners.contains_key(&button.trigger));
                if !active || slots == 0 {
                    state.lease = None;
                    continue;
                }
                let id = if let Some(id) = state.lease {
                    id
                } else {
                    let free = |&id: &u8| unavailable & (1 << id) == 0;
                    let preferred = Some(button.preferred)
                        .filter(|id| (3..=LAST_ID).contains(id))
                        .filter(free);
                    let Some(id) = preferred.or_else(|| (3..=LAST_ID).rev().find(free)) else {
                        continue;
                    };
                    state.lease = Some(id);
                    unavailable |= 1 << id;
                    id
                };
                slots -= 1;
                let mut point = button.point;
                if let Some(run) = &mut state.swipe {
                    // Waiting for admission must not consume gesture time.
                    let start = *run.start.get_or_insert(now);
                    let progress = ((now - start) / button.duration).clamp(0.0, 1.0);
                    if progress >= 1.0 {
                        point = button.end;
                        run.lift.get_or_insert(now + TICK);
                    } else {
                        point = point.lerp(button.end, progress);
                    }
                }
                self.scratch.push(Contact { id, point });
            }
        }
    }
}

// Read-only inspection for the deterministic preview API. Logical ownership
// can outlive any one physical source when a profile links multiple keys.
impl Engine {
    pub(crate) fn is_pressed(&self, key: u16) -> bool {
        self.owners.contains_key(&key)
    }

    pub(crate) fn is_down(&self, key: u16) -> bool {
        self.physical.contains(&key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(x: f64, y: f64) -> Point {
        Point { x, y }
    }
    fn b(trigger: u16, behavior: u8, preferred: u8) -> Button {
        Button {
            trigger,
            behavior,
            preferred,
            point: p(0.4, 0.2),
            end: p(0.8, 0.6),
            duration: 0.125,
        }
    }
    fn config() -> Config {
        Config {
            aspect: 2.0,
            joystick: p(0.2, 0.75),
            joystick_radius: 0.1,
            joystick_enabled: true,
            turn_duration: 0.0,
            smooth: false,
            look: p(0.6, 0.4),
            look_width: 0.38,
            look_height: 0.52,
            look_enabled: true,
            sensitivity: 1.0,
            swap_axes: false,
            invert_x: false,
            invert_y: false,
            mapping: 0,
            buttons: vec![],
            links: vec![],
        }
    }
    fn ids(frames: &[Vec<Contact>]) -> Vec<Vec<u8>> {
        frames
            .iter()
            .map(|f| f.iter().map(|c| c.id).collect())
            .collect()
    }
    fn near(actual: Point, expected: Point) {
        assert!(
            (actual.x - expected.x).abs() < 1e-12 && (actual.y - expected.y).abs() < 1e-12,
            "expected {:?}, got {:?}",
            expected,
            actual
        );
    }
    fn only(frames: Vec<Vec<Contact>>, id: u8, expected: Point) {
        assert_eq!(ids(&frames), [vec![id]]);
        near(frames[0][0].point, expected);
    }

    #[test]
    fn overlapping_direct_and_linked_owners_ignore_repeat_and_cursor_action() {
        let mut c = config();
        c.buttons = vec![
            b(12, HOLD, 4),
            b(13, TAP_BUTTON, 5),
            b(CURSOR_ACTION, HOLD, 6),
        ];
        // The Swift caller supplied closure 10 -> 11 -> 12,13 plus cursor action.
        c.links = vec![
            (10, 11),
            (10, 12),
            (10, 13),
            (10, CURSOR_ACTION),
            (11, 12),
            (11, 13),
        ];
        let mut e = Engine::new(c);
        assert_eq!(ids(&e.key(10, true, 0.0)), [vec![4, 5]]);
        assert!(e.key(10, true, 0.01).is_empty());
        assert!(e.key(11, true, 0.02).is_empty());
        assert!(e.key(12, true, 0.03).is_empty());
        assert!(e.key(10, false, 0.04).is_empty());
        assert!(e.key(11, false, 0.05).is_empty());
        assert!(e.key(CURSOR_ACTION, true, 0.06).is_empty());
        assert_eq!(ids(&e.advance(0.071)), [vec![4]]); // the second owner didn't rearm the tap
        assert_eq!(ids(&e.key(12, false, 0.08)), [Vec::<u8>::new()]);
        assert!(e.key(12, false, 0.09).is_empty());
        assert!(e.pointer_down(p(0.5, 0.5), 0.10).is_empty()); // Rust didn't toggle
    }

    #[test]
    fn taps_restart_with_an_up_and_pulsed_holds_expire() {
        let mut c = config();
        c.buttons = vec![b(10, TAP_BUTTON, 3), b(11, HOLD, 4)];
        let mut e = Engine::new(c);
        assert_eq!(ids(&e.pulse(1, 0.0)), [vec![4]]);
        assert_eq!(ids(&e.key(10, true, 0.01)), [vec![3, 4]]);
        assert!(e.key(10, false, 0.02).is_empty());
        assert_eq!(ids(&e.key(10, true, 0.03)), [vec![4], vec![3, 4]]);
        assert_eq!(ids(&e.pulse(0, 0.04)), [vec![4], vec![3, 4]]);
        assert_eq!(ids(&e.advance(0.070)), [vec![3]]);
        assert!(e.advance(0.105).is_empty());
        assert_eq!(ids(&e.advance(0.111)), [Vec::<u8>::new()]);
        assert!(e.pulse(9, 0.12).is_empty());
    }

    #[test]
    fn opposite_key_winner_anchor_and_fast_all_up_handoff() {
        let mut e = Engine::new(config());
        only(e.key(0, true, 0.0), 1, p(0.2, 0.75));
        assert!(e.key(2, true, 0.001).is_empty());
        assert!(e.key(0, true, 0.002).is_empty()); // repeat cannot override S
        assert!(e.advance(0.016).is_empty());
        only(e.advance(0.020), 1, p(0.2, 0.85));
        assert!(e.key(2, false, 0.025).is_empty());
        assert!(e.advance(0.030).is_empty());
        only(e.advance(0.034), 1, p(0.2, 0.65));
        assert!(e.key(0, false, 0.035).is_empty());
        let again = e.key(0, true, 0.036);
        assert_eq!(ids(&again), [vec![], vec![1]]);
        near(again[1][0].point, p(0.2, 0.75));
        assert!(e.advance(0.050).is_empty());
        only(e.advance(0.054), 1, p(0.2, 0.65));
    }

    #[test]
    fn diagonal_partial_release_freezes_across_other_edges_and_then_stops() {
        let mut c = config();
        c.buttons = vec![b(10, HOLD, 3)];
        let mut e = Engine::new(c);
        e.key(0, true, 0.0);
        e.key(3, true, 0.004);
        let d = 0.1 / 2.0_f64.sqrt();
        let diagonal = p(0.2 + d / 2.0, 0.75 - d);
        only(e.advance(0.025), 1, diagonal);
        assert!(e.key(0, false, 0.026).is_empty());
        let edge = e.key(10, true, 0.028);
        assert_eq!(ids(&edge), [vec![1, 3]]);
        near(edge[0][0].point, diagonal);
        e.key(3, false, 0.030);
        assert_eq!(ids(&e.advance(0.032)), [vec![3]]); // no spurious cardinal frame
    }

    #[test]
    fn manual_travel_begins_at_dwell_and_release_deadlines_not_late_ticks() {
        let mut c = config();
        c.turn_duration = 0.08;
        let mut e = Engine::new(c);
        e.key(0, true, 0.0);
        only(e.advance(1.0 / 60.0 + 0.04), 1, p(0.2, 0.70));
        e.advance(0.1);
        e.key(3, true, 0.11);
        let d = 1.0 / 2.0_f64.sqrt();
        only(e.advance(0.20), 1, p(0.2 + 0.05 * d, 0.75 - 0.1 * d));
        e.key(0, false, 0.21);
        // Released Y goes to zero immediately at coalescing deadline; remaining
        // distance on X interpolates at one radius per 80 ms from that instant.
        only(
            e.advance(0.21 + TICK + 0.008),
            1,
            p(0.2 + 0.05 * (d + 0.1), 0.75),
        );
    }

    #[test]
    fn smooth_steering_eases_the_whole_vector_from_last_sent_position() {
        let mut c = config();
        c.smooth = true;
        let mut e = Engine::new(c);
        e.key(0, true, 0.0);
        e.key(3, true, 0.001);
        let d = 1.0 / 2.0_f64.sqrt();
        let v = d * 0.875; // at 50 ms: 1 - (1 - 0.5)^3
        only(
            e.advance(1.0 / 60.0 + 0.050),
            1,
            p(0.2 + 0.05 * v, 0.75 - 0.1 * v),
        );
        assert!(e.key(3, false, 0.070).is_empty());
        assert!(e.advance(0.074).is_empty());
        only(
            e.advance(0.070 + TICK + 0.050),
            1,
            p(0.2 + 0.05 * v * 0.125, 0.75 - 0.1 * (v + (1.0 - v) * 0.875)),
        );
        only(e.advance(0.20), 1, p(0.2, 0.65));
    }

    #[test]
    fn swipe_restarts_after_lift_and_endpoint_survives_late_tick() {
        let mut c = config();
        c.buttons = vec![b(10, SWIPE, 6)];
        let mut e = Engine::new(c);
        only(e.key(10, true, 0.0), 6, p(0.4, 0.2));
        only(e.key(10, false, 0.0625), 6, p(0.6, 0.4));
        let frames = e.pulse(0, 0.080);
        assert_eq!(ids(&frames), [vec![], vec![6]]);
        near(frames[1][0].point, p(0.4, 0.2));
        only(e.advance(0.5), 6, p(0.8, 0.6));
        assert!(e.advance(0.505).is_empty());
        assert_eq!(ids(&e.advance(0.510)), [Vec::<u8>::new()]);
    }

    #[test]
    fn delayed_admission_starts_swipe_clock_and_avoids_same_snapshot_id_reuse() {
        let mut c = config();
        c.buttons = (0..10).map(|i| b(20 + i, HOLD, 3 + i as u8)).collect();
        c.buttons.push(b(30, SWIPE, 3));
        let mut e = Engine::new(c);
        for i in 0..10 {
            assert_eq!(e.key(20 + i, true, 0.0)[0].len(), i as usize + 1);
        }
        assert!(e.pulse(10, 0.01).is_empty());
        assert!(e.advance(0.5).is_empty());
        let frames = e.key(20, false, 1.0);
        assert_eq!(ids(&frames), [vec![4, 5, 6, 7, 8, 9, 10, 11, 12, 16]]);
        near(frames[0][9].point, p(0.4, 0.2));
        near(e.advance(1.0625)[0][9].point, p(0.6, 0.4));
        near(e.advance(1.15)[0][9].point, p(0.8, 0.6));
        assert_eq!(ids(&e.advance(1.17)), [vec![4, 5, 6, 7, 8, 9, 10, 11, 12]]);
    }

    #[test]
    fn cursor_transition_lifts_mouse_only_then_flushes_pointer_drag_before_up() {
        let mut c = config();
        c.buttons = vec![b(4, HOLD, 3), b(5, TAP_BUTTON, 4), b(10, HOLD, 5)];
        let mut e = Engine::new(c);
        e.key(4, true, 0.0);
        e.key(5, true, 0.0);
        e.key(10, true, 0.0);
        e.mouse(15.0, 0.0, 0.01);
        assert_eq!(ids(&e.advance(0.01)), [vec![2, 3, 4, 5]]);
        assert_eq!(ids(&e.set_cursor(true, 0.011)), [vec![5]]);
        assert!(e.key(4, true, 0.012).is_empty());
        e.mouse(120.0, 10.0, 0.013);
        assert!(e.pointer_down(p(f64::NAN, 0.5), 0.014).is_empty());
        assert_eq!(ids(&e.pointer_down(p(0.25, 0.75), 0.015)), [vec![2, 5]]);
        assert!(e.pointer_down(p(0.5, 0.5), 0.016).is_empty());
        e.pointer_move(p(0.7, 0.3));
        e.pointer_move(p(-0.1, 0.5));
        let up = e.pointer_up(0.02);
        assert_eq!(ids(&up), [vec![2, 5], vec![5]]);
        near(up[0][0].point, p(0.7, 0.3));
        e.set_cursor(false, 0.022);
        assert!(e.advance(0.023).is_empty()); // no look resurrection
        assert_eq!(ids(&e.key(4, true, 0.024)), [vec![3, 5]]);
    }

    #[test]
    fn look_consumes_one_capped_aggregate_only_on_tick_then_idles() {
        let mut c = config();
        c.buttons = vec![b(10, HOLD, 3)];
        let mut e = Engine::new(c);
        e.mouse(60.0, 0.0, 0.0);
        e.mouse(10000.0, 0.0, 0.001);
        assert_eq!(ids(&e.key(10, true, 0.002)), [vec![3]]);
        near(e.advance(0.003)[0][0].point, p(0.6, 0.4));
        assert!(e.advance(0.003).is_empty()); // even a duplicate tick can't consume twice
        let edge = e.key(10, false, 0.005);
        only(edge, 2, p(0.6, 0.4));
        only(e.advance(0.012), 2, p(0.7, 0.4));
        for i in 2..=16 {
            assert!(e.advance(i as f64 * 0.009).is_empty());
        }
        e.mouse(0.0, 0.0, 0.148); // no idle extension
        assert_eq!(ids(&e.advance(0.152)), [Vec::<u8>::new()]);
    }

    #[test]
    fn look_aggregates_before_capping_and_samples_cannot_refresh_an_old_bucket() {
        let mut e = Engine::new(config());
        e.mouse(100000.0, 0.0, 0.0);
        e.mouse(-100000.0, 0.0, 0.001);
        assert!(e.advance(0.002).is_empty());
        e.mouse(20000.0, 0.0, 0.010);
        e.mouse(1.0, 0.0, 0.025);
        e.mouse(-5.0, 0.0, 0.040); // stalled beyond freshness of the original bucket
        only(e.advance(0.041), 2, p(0.6, 0.4));
        only(e.advance(0.050), 2, p(0.594, 0.4));
    }

    #[test]
    fn boundary_rebase_lifts_only_look_then_reanchors_for_one_tick() {
        let mut c = config();
        c.look_width = 0.20;
        c.buttons = vec![b(10, HOLD, 3)];
        let mut e = Engine::new(c);
        e.key(10, true, 0.0);
        e.mouse(1000.0, 0.0, 0.001);
        near(e.advance(0.001)[0][0].point, p(0.6, 0.4));
        near(e.advance(0.010)[0][0].point, p(0.69, 0.4));
        e.mouse(1000.0, 0.0, 0.017);
        assert_eq!(ids(&e.advance(0.018)), [vec![3]]);
        near(e.advance(0.027)[0][0].point, p(0.6, 0.4));
        near(e.advance(0.035)[0][0].point, p(0.69, 0.4));
        assert!(e.advance(0.044).is_empty());
        e.mouse(1000.0, 0.0, 0.05);
        assert_eq!(ids(&e.advance(0.05)), [vec![3]]);
        assert!(e.advance(0.10).is_empty()); // no stale rebase attempt
    }

    #[test]
    fn stale_anchor_motion_dies_and_new_samples_win_over_deferred_motion() {
        let mut e = Engine::new(config());
        e.mouse(10000.0, 0.0, 0.0);
        assert!(e.advance(0.10).is_empty()); // no stale first down
        e.mouse(10000.0, 0.0, 0.11);
        only(e.advance(0.11), 2, p(0.6, 0.4));
        assert!(e.advance(0.15).is_empty()); // no stale first drag
        e.advance(0.27);
        e.mouse(10000.0, 0.0, 0.28);
        only(e.advance(0.28), 2, p(0.6, 0.4));
        e.mouse(-10.0, 0.0, 0.282);
        e.mouse(-5.0, 0.0, 0.284);
        only(e.advance(0.29), 2, p(0.582, 0.4)); // both new samples; no old positive flick
    }

    #[test]
    fn swapped_inverted_mouse_respects_aspect_and_invalid_samples_dont_extend_idle() {
        let mut c = config();
        c.swap_axes = true;
        c.invert_y = true;
        c.invert_x = true;
        c.sensitivity = 2.0;
        let mut e = Engine::new(c);
        e.set_aspect(1.5);
        e.set_aspect(f64::INFINITY);
        e.mouse(2.0, -3.0, 0.0);
        only(e.advance(0.0), 2, p(0.6, 0.4));
        only(e.advance(0.010), 2, p(0.6072, 0.3928));
        e.mouse(f64::NAN, 1.0, 0.14);
        assert_eq!(ids(&e.advance(0.16)), [Vec::<u8>::new()]);
    }

    #[test]
    fn mapping_offsets_clamp_before_rotation_then_mirror_on_all_contact_paths() {
        let mut c = config();
        c.buttons = vec![b(10, HOLD, 5)];
        c.mapping = 1 | 4 | 8;
        let mut e = Engine::new(c);
        e.set_offset(-0.125, 0.25);
        near(e.mapped(p(0.1, 0.95)), p(0.0, 0.0));
        only(e.key(10, true, 0.0), 5, p(0.55, 0.275));
        e.set_cursor(true, 0.01);
        let frames = e.pointer_down(p(0.75, 0.25), 0.02);
        near(frames[0][0].point, p(0.5, 0.625));
        for (rotation, expected) in [
            (0, p(0.2, 0.3)),
            (1, p(0.3, 0.8)),
            (2, p(0.8, 0.7)),
            (3, p(0.7, 0.2)),
        ] {
            let mut c = config();
            c.mapping = rotation;
            near(Engine::new(c).mapped(p(0.2, 0.3)), expected);
        }
    }
}
