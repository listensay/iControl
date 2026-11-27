//! One writer/engine owner per authenticated session. Producers never wait on I/O.
use crate::engine::{Contact, Engine, Point};
use crate::wire::Wire;
use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

#[cfg(test)]
#[path = "mailbox_tests.rs"]
mod mailbox_tests;

const TICK: Duration = Duration::from_nanos(8_333_333);
const HEARTBEAT: Duration = Duration::from_millis(100);
const FRESH: Duration = Duration::from_millis(25);
const EDGE_LIMIT: usize = 128;
const MAX_WAIT: Duration = Duration::from_millis(150);

pub struct Capture {
    pub engine: Engine,
    pub orientation: u8,
    pub presets: Vec<u8>, // preferred touch ID -> find its enabled button index
    cursor: bool,
    visible: Option<Point>, // last cursor actually written, in displayed axes
}
impl Capture {
    pub fn new(engine: Engine, orientation: u8, presets: Vec<u8>) -> Self {
        Self {
            engine,
            orientation,
            presets,
            cursor: false,
            visible: None,
        }
    }
    fn show(&mut self, wire: &mut Wire, point: Option<Point>) -> Result<(), String> {
        if self.visible != point {
            wire.cursor(self.orientation, point.map(|p| self.engine.mapped(p)))?;
            self.visible = point;
        }
        Ok(())
    }
    fn apply(&mut self, motion: Motion, sampled: f64, wire: &mut Wire) -> Result<(), String> {
        match motion {
            Motion::Delta(p) => self.engine.mouse(p.x, p.y, sampled),
            Motion::Pointer(p) if self.cursor => {
                if let Some(p) = p {
                    self.engine.pointer_move(p);
                }
                self.show(wire, p)?;
            }
            _ => (),
        }
        Ok(())
    }
}

pub enum Edge {
    Start(Box<Capture>),
    Release,
    Key(u16, bool),
    Pulse(u8),
    Mode(bool),
    Aspect(f64),
    Down(Point),
    Up(Option<Sample>),
    Preview(u8, Vec<Contact>),
    Cursor(u8, Option<Point>),
}
#[derive(Clone, Copy, Debug)]
pub enum Motion {
    Delta(Point),
    Pointer(Option<Point>),
}
#[derive(Clone, Copy, Debug)]
pub struct Sample {
    when: Instant,
    motion: Motion,
}
impl Sample {
    fn fresh(self, now: Instant) -> bool {
        now.saturating_duration_since(self.when) <= FRESH
    }
}
#[derive(Default)]
struct Inbox {
    edges: VecDeque<(Instant, Edge)>,
    motion: Option<Sample>,
    stopped: bool,
    overflow: bool,
}
impl Inbox {
    fn edge(&mut self, mut edge: Edge, now: Instant) -> bool {
        if self.stopped || self.overflow {
            return false;
        }
        match &mut edge {
            // Release cancels rather than replays old-session work. It is itself a barrier:
            // a new capture/preview cannot overtake it on the same writer.
            Edge::Release => {
                self.edges.clear();
                self.motion = None;
            }
            Edge::Start(_) | Edge::Mode(_) | Edge::Down(_) => self.motion = None,
            Edge::Up(last) => {
                *last = self
                    .motion
                    .take()
                    .filter(|s| matches!(s.motion, Motion::Pointer(_)))
            }
            _ => (),
        }
        if self.edges.len() >= EDGE_LIMIT {
            self.overflow = true;
            self.edges.clear();
            self.motion = None;
            return false;
        }
        self.edges.push_back((now, edge));
        true
    }
    fn sample(&mut self, motion: Motion, when: Instant, now: Instant) {
        if self.stopped || self.overflow || now.saturating_duration_since(when) > FRESH {
            return;
        }
        if let Motion::Delta(p) = motion {
            if let Some(last) = &mut self.motion {
                if let Motion::Delta(sum) = &mut last.motion {
                    if now.saturating_duration_since(last.when) <= FRESH {
                        sum.x = (p.x + sum.x).clamp(f64::MIN, f64::MAX);
                        sum.y = (p.y + sum.y).clamp(f64::MIN, f64::MAX);
                        last.when = last.when.min(when); // later samples can't renew a stalled burst
                        return;
                    }
                }
            }
        }
        self.motion = Some(Sample { when, motion });
    }
}

#[derive(Default)]
pub struct Mailbox {
    inner: Mutex<Inbox>,
    wake: Condvar,
}
impl Mailbox {
    pub fn edge(&self, edge: Edge) -> bool {
        let ok = self.inner.lock().unwrap().edge(edge, Instant::now());
        self.wake.notify_one();
        ok
    }
    pub fn sample(&self, motion: Motion, age: f64) {
        if !(0.0..=FRESH.as_secs_f64()).contains(&age) {
            return;
        }
        let now = Instant::now();
        if let Some(when) = now.checked_sub(Duration::from_secs_f64(age)) {
            self.inner.lock().unwrap().sample(motion, when, now);
        }
        // No wake per mouse event. Only the input clock consumes this slot.
    }
    pub fn stop(&self) {
        let mut q = self.inner.lock().unwrap();
        q.stopped = true;
        q.edges.clear();
        q.motion = None;
        self.wake.notify_one();
    }
    fn take_motion(&self, now: Instant) -> Option<Sample> {
        let mut q = self.inner.lock().unwrap();
        // Never apply motion before an earlier mode/down edge has been dispatched.
        if q.edges.is_empty() {
            q.motion.take().filter(|s| s.fresh(now))
        } else {
            None
        }
    }
    fn next(&self, deadline: Instant) -> Result<Work, String> {
        let mut q = self.inner.lock().unwrap();
        loop {
            if q.overflow {
                return Err("FPS 按键队列已满，已停止输入，请重新连接。".into());
            }
            if q.stopped {
                return Ok(Work::Stop);
            }
            let now = Instant::now();
            if matches!(q.edges.front(), Some((_, Edge::Release))) {
                q.edges.pop_front();
                return Ok(Work::Edge(Edge::Release));
            }
            if let Some((stamp, _)) = q.edges.front() {
                if now.duration_since(*stamp) > MAX_WAIT {
                    return Err("FPS 按键发送延迟过高，已停止输入，请重新连接。".into());
                }
            }
            if now >= deadline {
                return Ok(Work::Deadline);
            }
            if let Some((_, edge)) = q.edges.pop_front() {
                return Ok(Work::Edge(edge));
            }
            q = self.wake.wait_timeout(q, deadline - now).unwrap().0;
        }
    }
}
enum Work {
    Stop,
    Edge(Edge),
    Deadline,
}

fn send(wire: &mut Wire, orientation: u8, frames: Vec<Vec<Contact>>) -> Result<(), String> {
    for frame in frames {
        wire.state(orientation, &frame)?;
    }
    Ok(())
}

pub fn run(mailbox: &Mailbox, wire: &mut Wire) -> Result<(), String> {
    let origin = Instant::now();
    let mut capture: Option<Box<Capture>> = None;
    let mut beat = origin;
    let mut tick = origin;
    loop {
        let due = if capture.is_some() {
            tick.min(beat)
        } else {
            beat
        };
        let work = mailbox.next(due)?;
        let now = Instant::now();
        let t = now.duration_since(origin).as_secs_f64();
        if !wire.healthy() {
            return Err("FPS 输入连接中断，已停止输入。".into());
        }
        match work {
            Work::Stop => return Ok(()),
            Work::Deadline => {
                if let Some(c) = &mut capture {
                    if now >= tick {
                        if wire.drained() {
                            if let Some(s) = mailbox.take_motion(now) {
                                c.apply(
                                    s.motion,
                                    s.when.saturating_duration_since(origin).as_secs_f64(),
                                    wire,
                                )?;
                            }
                            send(wire, c.orientation, c.engine.advance(t))?;
                        }
                        // Preserve phase when slightly late, but skip every missed period.
                        tick += TICK;
                        if tick <= Instant::now() {
                            tick = Instant::now() + TICK;
                        }
                    }
                }
                if now >= beat {
                    if wire.drained() {
                        wire.heartbeat()?;
                    }
                    beat = Instant::now() + HEARTBEAT;
                }
            }
            Work::Edge(edge) => match edge {
                Edge::Release => {
                    capture = None;
                    wire.release()?;
                }
                Edge::Start(c) => {
                    wire.state(c.orientation, &[])?;
                    capture = Some(c);
                    tick = now + TICK;
                }
                Edge::Preview(o, contacts) => {
                    if capture.is_none() {
                        wire.state(o, &contacts)?;
                    }
                }
                Edge::Cursor(o, point) => wire.cursor(o, point)?,
                edge => {
                    let Some(c) = &mut capture else {
                        continue;
                    };
                    let frames = match edge {
                        Edge::Key(k, down) => c.engine.key(k, down, t),
                        Edge::Pulse(p) => match c.presets.iter().position(|&id| id == p) {
                            Some(index) => c.engine.pulse(index, t),
                            None => continue,
                        },
                        Edge::Aspect(v) => {
                            c.engine.set_aspect(v);
                            continue;
                        }
                        Edge::Down(p) if c.cursor => {
                            c.show(wire, Some(p))?;
                            c.engine.pointer_down(p, t)
                        }
                        Edge::Up(last) => {
                            if let Some(s) = last.filter(|s| s.fresh(now)) {
                                c.apply(s.motion, t, wire)?;
                            }
                            c.engine.pointer_up(t)
                        }
                        Edge::Mode(on) => {
                            c.cursor = on;
                            let frames = c.engine.set_cursor(on, t);
                            send(wire, c.orientation, frames)?;
                            c.show(wire, on.then_some(Point { x: 0.5, y: 0.5 }))?;
                            continue;
                        }
                        _ => continue,
                    };
                    send(wire, c.orientation, frames)?;
                }
            },
        }
    }
}
