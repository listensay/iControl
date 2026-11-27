use super::Point;

const ANCHOR: f64 = 1.0 / 60.0;
const SETTLING: f64 = 0.100;

#[derive(Clone, Copy)]
struct Travel {
    from: Point,
    start: f64,
    duration: f64,
    smooth: bool,
}

/// Coordinates here are fractions of a radius, not framebuffer coordinates.
#[derive(Clone, Default)]
pub(super) struct Joystick {
    anchor: Option<f64>,
    dragged: bool,
    current: Point,
    target: Point,
    travel: Option<Travel>,
}

impl Joystick {
    pub(super) fn direction(&self) -> Option<Point> {
        self.anchor.map(|_| self.current)
    }

    pub(super) fn freeze(&mut self) {
        self.target = self.current;
        self.travel = None;
    }

    pub(super) fn advance(&mut self, keys: &[u16], now: f64, duration: f64, smooth: bool) {
        if keys.is_empty() {
            *self = Self::default();
            return;
        }
        // Physical press order, not key-code order; repeats never get appended.
        let x: f64 = match keys.iter().rev().find(|&&k| k == 1 || k == 3) {
            Some(1) => -1.0,
            Some(3) => 1.0,
            _ => 0.0,
        };
        let y: f64 = match keys.iter().rev().find(|&&k| k == 0 || k == 2) {
            Some(0) => -1.0,
            Some(2) => 1.0,
            _ => 0.0,
        };
        let length = x.hypot(y);
        let next = Point {
            x: x / length,
            y: y / length,
        };
        let anchor = *self.anchor.get_or_insert(now);
        if now - anchor < ANCHOR {
            self.target = next;
            return;
        }
        if !self.dragged {
            self.dragged = true;
            self.begin(next, anchor + ANCHOR, duration, smooth);
        } else {
            self.update(now);
            if self.target != next {
                if !smooth {
                    if next.x == 0.0 {
                        self.current.x = 0.0;
                    }
                    if next.y == 0.0 {
                        self.current.y = 0.0;
                    }
                }
                self.begin(next, now, duration, smooth);
            }
        }
        self.update(now);
    }

    fn begin(&mut self, next: Point, start: f64, duration: f64, smooth: bool) {
        let distance = (next.x - self.current.x)
            .abs()
            .max((next.y - self.current.y).abs());
        self.target = next;
        let duration = if smooth {
            SETTLING
        } else {
            duration * distance
        };
        if distance == 0.0 || duration == 0.0 {
            self.current = next;
            self.travel = None;
        } else {
            self.travel = Some(Travel {
                from: self.current,
                start,
                duration,
                smooth,
            });
        }
    }

    fn update(&mut self, now: f64) {
        if let Some(travel) = self.travel {
            let t = ((now - travel.start) / travel.duration).clamp(0.0, 1.0);
            if t == 1.0 {
                self.current = self.target;
                self.travel = None;
            } else {
                let rest = 1.0 - t;
                let fraction = if travel.smooth {
                    1.0 - rest * rest * rest
                } else {
                    t
                };
                self.current = travel.from.lerp(self.target, fraction);
            }
        }
    }
}
