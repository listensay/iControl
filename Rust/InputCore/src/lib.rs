//! Host-only C ABI. The caller owns each opaque handle until destroy and must
//! keep it alive while calling. Only ic_fps_open performs synchronous I/O.
mod engine;
mod offline;
mod wire;
mod worker;

use engine::{Button, Config, Contact, Engine, Point};
use std::ffi::{c_char, c_void, CString};
use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::{ptr, slice, thread};
use wire::{Notice, Wire};
use worker::{Capture, Edge, Mailbox, Motion};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ICPoint {
    x: f64,
    y: f64,
}
impl From<ICPoint> for Point {
    fn from(p: ICPoint) -> Self {
        Self { x: p.x, y: p.y }
    }
}
impl From<Point> for ICPoint {
    fn from(p: Point) -> Self {
        Self { x: p.x, y: p.y }
    }
}
impl ICPoint {
    fn valid(self) -> bool {
        (0.0..=1.0).contains(&self.x) && (0.0..=1.0).contains(&self.y)
    }
}
#[repr(C)]
pub struct ICProfile {
    joystick: ICPoint,
    look: ICPoint,
    offset: ICPoint,
    aspect: f64,
    radius: f64,
    turn_duration: f64,
    look_width: f64,
    look_height: f64,
    sensitivity: f64,
    joystick_enabled: u8,
    smooth: u8,
    look_enabled: u8,
    swap_axes: u8,
    invert_x: u8,
    invert_y: u8,
    mapping: u8,
    orientation: u8,
}
#[repr(C)]
pub struct ICButton {
    point: ICPoint,
    end: ICPoint,
    duration: f64,
    trigger: u16,
    behavior: u8,
    preferred: u8,
}
#[repr(C)]
pub struct ICLinkKey {
    source: u16,
    target: u16,
}
#[repr(C)]
pub struct ICContact {
    point: ICPoint,
    id: u8,
}

// Pointer is borrowed for one FFI call. Empty Swift buffers may have NULL baseAddress.
unsafe fn borrow<'a, T>(p: *const T, n: usize, max: usize) -> Option<&'a [T]> {
    if n == 0 {
        Some(&[])
    } else if n > max || p.is_null() {
        None
    } else {
        Some(slice::from_raw_parts(p, n))
    }
}
fn profile(p: &ICProfile, buttons: &[ICButton], links: &[ICLinkKey]) -> Engine {
    let mut e = Engine::new(Config {
        aspect: p.aspect,
        joystick: p.joystick.into(),
        joystick_radius: p.radius,
        turn_duration: p.turn_duration,
        look: p.look.into(),
        look_width: p.look_width,
        look_height: p.look_height,
        sensitivity: p.sensitivity,
        joystick_enabled: p.joystick_enabled != 0,
        smooth: p.smooth != 0,
        look_enabled: p.look_enabled != 0,
        swap_axes: p.swap_axes != 0,
        invert_x: p.invert_x != 0,
        invert_y: p.invert_y != 0,
        mapping: p.mapping,
        buttons: buttons
            .iter()
            .map(|b| Button {
                trigger: b.trigger,
                behavior: b.behavior,
                point: b.point.into(),
                end: b.end.into(),
                duration: b.duration,
                preferred: b.preferred,
            })
            .collect(),
        links: links.iter().map(|l| (l.source, l.target)).collect(),
    });
    e.set_offset(p.offset.x, p.offset.y);
    e
}

type Notify = extern "C" fn(*mut c_void, i32, f64, u8, u8, *const c_char);
type Dispose = extern "C" fn(*mut c_void);
struct Receiver {
    context: *mut c_void,
    notify: Notify,
    dispose: Dispose,
    failed: AtomicBool,
}
// Context is a retained immutable Swift box containing a @Sendable closure.
unsafe impl Send for Receiver {}
unsafe impl Sync for Receiver {}
impl Drop for Receiver {
    fn drop(&mut self) {
        (self.dispose)(self.context);
    }
}
impl Receiver {
    fn post(&self, n: Notice) {
        match n {
            Notice::Ack(ms, a, b) => (self.notify)(self.context, 1, ms, a, b, ptr::null()),
            Notice::Cursor(a, b) => {
                (self.notify)(self.context, 2, 0.0, a as u8, b as u8, ptr::null())
            }
            Notice::Failed(s) => {
                if !self.failed.swap(true, Ordering::AcqRel) {
                    let message = CString::new(s).unwrap_or_default();
                    (self.notify)(self.context, 3, 0.0, 0, 0, message.as_ptr());
                }
            }
        }
    }
}
pub struct ICFpsLink(Arc<Mailbox>);
unsafe fn message(buf: *mut c_char, cap: usize, text: &str) {
    if cap != 0 && !buf.is_null() {
        let mut n = (cap - 1).min(text.len());
        while !text.is_char_boundary(n) {
            n -= 1;
        }
        ptr::copy_nonoverlapping(text.as_ptr(), buf.cast(), n);
        *buf.add(n) = 0;
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_fps_open(
    fd: i32,
    secret: *const u8,
    n: usize,
    context: *mut c_void,
    notify: Notify,
    dispose: Dispose,
    supports: *mut u8,
    error: *mut c_char,
    cap: usize,
) -> *mut ICFpsLink {
    let receiver = Arc::new(Receiver {
        context,
        notify,
        dispose,
        failed: AtomicBool::new(false),
    });
    let open = || -> Result<_, String> {
        if fd < 0 {
            return Err("FPS 连接已关闭".into());
        }
        let stream = UnixStream::from_raw_fd(fd);
        let secret = borrow(secret, n, 32).ok_or("FPS 凭据无效")?;
        let ack = Arc::clone(&receiver);
        let mut wire = Wire::connect(stream, secret, Arc::new(move |n| ack.post(n)))?;
        let mailbox = Arc::new(Mailbox::default());
        let worker = Arc::clone(&mailbox);
        if let Some(flag) = supports.as_mut() {
            *flag = wire.supports_cursor() as u8;
        }
        thread::Builder::new()
            .name("fps-input".into())
            .spawn(move || {
                #[cfg(target_os = "macos")]
                {
                    extern "C" {
                        fn pthread_set_qos_class_self_np(class: u32, relative_priority: i32)
                            -> i32;
                    }
                    pthread_set_qos_class_self_np(0x21, 0);
                } // QOS_CLASS_USER_INTERACTIVE
                let result = worker::run(&worker, &mut wire);
                worker.stop();
                if wire.healthy() {
                    let _ = wire.release();
                }
                wire.close(); // join the ACK reader here, never in Swift deinit
                if let Err(e) = result {
                    receiver.post(Notice::Failed(e));
                }
            })
            .map_err(|e| format!("无法启动 FPS 输入线程：{e}"))?;
        Ok(Box::into_raw(Box::new(ICFpsLink(mailbox))))
    };
    match open() {
        Ok(l) => l,
        Err(e) => {
            message(error, cap, &e);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_fps_capture(
    h: &ICFpsLink,
    raw: *const ICProfile,
    bp: *const ICButton,
    n: usize,
    lp: *const ICLinkKey,
    m: usize,
) -> i32 {
    let (Some(p), Some(b), Some(l)) = (raw.as_ref(), borrow(bp, n, 64), borrow(lp, m, 4096)) else {
        return 0;
    };
    if !(p.look_width >= 0.0 && p.look_height >= 0.0) {
        return 0;
    }
    let c = Capture::new(
        profile(p, b, l),
        p.orientation,
        b.iter().map(|b| b.preferred).collect(),
    );
    h.0.edge(Edge::Start(Box::new(c))) as i32
}
#[no_mangle]
pub extern "C" fn ic_fps_key(h: &ICFpsLink, k: u16, down: u8) {
    h.0.edge(Edge::Key(k, down != 0));
}
#[no_mangle]
pub extern "C" fn ic_fps_mode(h: &ICFpsLink, on: u8) {
    h.0.edge(Edge::Mode(on != 0));
}
#[no_mangle]
pub extern "C" fn ic_fps_pulse(h: &ICFpsLink, id: u8) {
    h.0.edge(Edge::Pulse(id));
}
#[no_mangle]
pub extern "C" fn ic_fps_aspect(h: &ICFpsLink, v: f64) {
    h.0.edge(Edge::Aspect(v));
}
#[no_mangle]
pub extern "C" fn ic_fps_mouse(h: &ICFpsLink, p: ICPoint, age: f64) {
    if p.x.is_finite() && p.y.is_finite() {
        h.0.sample(Motion::Delta(p.into()), age);
    }
}
#[no_mangle]
pub extern "C" fn ic_fps_pointer_down(h: &ICFpsLink, p: ICPoint) {
    if p.valid() {
        h.0.edge(Edge::Down(p.into()));
    }
}
#[no_mangle]
pub extern "C" fn ic_fps_pointer_up(h: &ICFpsLink) {
    h.0.edge(Edge::Up(None));
}
#[no_mangle]
pub extern "C" fn ic_fps_pointer_move(h: &ICFpsLink, p: ICPoint, age: f64) {
    if p.valid() {
        h.0.sample(Motion::Pointer(Some(p.into())), age);
    }
}
#[no_mangle]
pub extern "C" fn ic_fps_pointer_hide(h: &ICFpsLink) {
    h.0.sample(Motion::Pointer(None), 0.0);
}
#[no_mangle]
pub unsafe extern "C" fn ic_fps_cursor(h: &ICFpsLink, o: u8, p: *const ICPoint) {
    h.0.edge(Edge::Cursor(o, p.as_ref().copied().map(Point::from)));
}
#[no_mangle]
pub unsafe extern "C" fn ic_fps_state(h: &ICFpsLink, o: u8, p: *const ICContact, n: usize) {
    if let Some(s) = borrow(p, n, 10) {
        h.0.edge(Edge::Preview(
            o,
            s.iter()
                .map(|c| Contact {
                    id: c.id,
                    point: c.point.into(),
                })
                .collect(),
        ));
    }
}
#[no_mangle]
pub extern "C" fn ic_fps_release(h: &ICFpsLink) {
    h.0.edge(Edge::Release);
}
#[no_mangle]
pub extern "C" fn ic_fps_stop(h: &ICFpsLink) {
    h.0.stop();
}
#[no_mangle]
pub unsafe extern "C" fn ic_fps_destroy(h: *mut ICFpsLink) {
    if !h.is_null() {
        let h = Box::from_raw(h);
        h.0.stop();
    }
}
