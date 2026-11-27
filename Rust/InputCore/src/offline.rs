//! Synchronous, transport-free adapter for Swift layout previews. The only
//! state behind this handle is the same Engine used by the live worker.
use crate::engine::{Contact, Engine};
use crate::{borrow, profile, ICButton, ICContact, ICLinkKey, ICPoint, ICProfile};
use std::{ffi::c_void, ptr};

pub struct ICOffline(Engine);
type Frame = Option<extern "C" fn(*mut c_void, *const ICContact, usize)>;

fn deliver(frames: Vec<Vec<Contact>>, context: *mut c_void, receive: Frame) {
    if let Some(receive) = receive {
        for frame in frames {
            let contacts: Vec<_> = frame
                .into_iter()
                .map(|c| ICContact {
                    point: c.point.into(),
                    id: c.id,
                })
                .collect();
            receive(context, contacts.as_ptr(), contacts.len());
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_create(
    raw: *const ICProfile,
    buttons: *const ICButton,
    n: usize,
    links: *const ICLinkKey,
    m: usize,
) -> *mut ICOffline {
    let (Some(raw), Some(buttons), Some(links)) =
        (raw.as_ref(), borrow(buttons, n, 64), borrow(links, m, 4096))
    else {
        return ptr::null_mut();
    };
    // A negative look cap is not a valid clamp range in the engine. The
    // Swift profile serializer normally enforces tighter layout bounds.
    if !(raw.look_width >= 0.0 && raw.look_height >= 0.0) {
        return ptr::null_mut();
    }
    Box::into_raw(Box::new(ICOffline(profile(raw, buttons, links))))
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_clone(h: *const ICOffline) -> *mut ICOffline {
    h.as_ref().map_or(ptr::null_mut(), |h| {
        Box::into_raw(Box::new(ICOffline(h.0.clone())))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_destroy(h: *mut ICOffline) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_aspect(h: *mut ICOffline, value: f64) {
    if let Some(h) = h.as_mut() {
        h.0.set_aspect(value);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_pressed(h: *const ICOffline, key: u16) -> u8 {
    h.as_ref().is_some_and(|h| h.0.is_pressed(key)) as u8
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_key(
    h: *mut ICOffline,
    key: u16,
    down: u8,
    now: f64,
    context: *mut c_void,
    receive: Frame,
) -> u8 {
    let Some(h) = h.as_mut().filter(|_| now.is_finite()) else {
        return 0;
    };
    let new_down = down != 0 && !h.0.is_down(key);
    let frames = h.0.key(key, down != 0, now);
    let accepted = new_down && h.0.is_down(key);
    deliver(frames, context, receive);
    accepted as u8
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_pulse(
    h: *mut ICOffline,
    index: usize,
    now: f64,
    context: *mut c_void,
    receive: Frame,
) {
    if let Some(h) = h.as_mut().filter(|_| now.is_finite()) {
        deliver(h.0.pulse(index, now), context, receive);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_mode(
    h: *mut ICOffline,
    on: u8,
    now: f64,
    context: *mut c_void,
    receive: Frame,
) {
    if let Some(h) = h.as_mut().filter(|_| now.is_finite()) {
        deliver(h.0.set_cursor(on != 0, now), context, receive);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_mouse(h: *mut ICOffline, delta: ICPoint, now: f64) {
    if let Some(h) = h.as_mut().filter(|_| now.is_finite()) {
        h.0.mouse(delta.x, delta.y, now);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_pointer_down(
    h: *mut ICOffline,
    point: ICPoint,
    now: f64,
    context: *mut c_void,
    receive: Frame,
) {
    if let Some(h) = h.as_mut().filter(|_| now.is_finite()) {
        deliver(h.0.pointer_down(point.into(), now), context, receive);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_pointer_move(h: *mut ICOffline, point: ICPoint) {
    if let Some(h) = h.as_mut() {
        h.0.pointer_move(point.into());
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_pointer_up(
    h: *mut ICOffline,
    now: f64,
    context: *mut c_void,
    receive: Frame,
) {
    if let Some(h) = h.as_mut().filter(|_| now.is_finite()) {
        deliver(h.0.pointer_up(now), context, receive);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ic_offline_advance(
    h: *mut ICOffline,
    now: f64,
    context: *mut c_void,
    receive: Frame,
) {
    if let Some(h) = h.as_mut().filter(|_| now.is_finite()) {
        deliver(h.0.advance(now), context, receive);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::slice;

    type Frames = Vec<Vec<Contact>>;
    extern "C" fn collect(context: *mut c_void, contacts: *const ICContact, count: usize) {
        unsafe {
            let result = &mut *context.cast::<Frames>();
            result.push(
                slice::from_raw_parts(contacts, count)
                    .iter()
                    .map(|c| Contact {
                        id: c.id,
                        point: crate::engine::Point {
                            x: c.point.x,
                            y: c.point.y,
                        },
                    })
                    .collect(),
            );
        }
    }

    #[test]
    fn ffi_preserves_snapshots_multi_edge_events_and_clone_isolation() {
        // All fields of the C profile are numbers/points. Only look and pointer
        // input are used by this fixture; use a nonidentity mapping on both.
        let mut raw: ICProfile = unsafe { std::mem::zeroed() };
        raw.aspect = 1.5;
        raw.look = ICPoint { x: 0.5, y: 0.5 };
        raw.look_enabled = 1;
        raw.look_width = 0.4;
        raw.look_height = 0.5;
        raw.sensitivity = 1.0;
        raw.mapping = 1;
        let mut engine = profile(&raw, &[], &[]);
        let mut frames = Frames::new();
        let ctx = (&mut frames as *mut Frames).cast();
        unsafe {
            let h = ic_offline_create(&raw, ptr::null(), 0, ptr::null(), 0);
            assert!(!h.is_null());
            ic_offline_mouse(h, ICPoint { x: 20.0, y: 0.0 }, 0.0);
            engine.mouse(20.0, 0.0, 0.0);
            ic_offline_advance(h, 0.0, ctx, Some(collect));
            assert_eq!(std::mem::take(&mut frames), engine.advance(0.0));
            let copy = ic_offline_clone(h); // includes the deferred first drag
            ic_offline_mode(h, 1, 0.005, ctx, Some(collect));
            assert_eq!(std::mem::take(&mut frames), vec![vec![]]);
            ic_offline_advance(copy, 0.01, ctx, Some(collect));
            assert_eq!(std::mem::take(&mut frames), engine.advance(0.01));
            ic_offline_destroy(copy);

            engine.set_cursor(true, 0.02);
            let p = crate::engine::Point { x: 0.2, y: 0.3 };
            ic_offline_pointer_down(h, p.into(), 0.03, ctx, Some(collect));
            assert_eq!(std::mem::take(&mut frames), engine.pointer_down(p, 0.03));
            let p = crate::engine::Point { x: 0.7, y: 0.4 };
            ic_offline_pointer_move(h, p.into());
            engine.pointer_move(p);
            ic_offline_pointer_up(h, 0.04, ctx, Some(collect));
            assert_eq!(frames.len(), 2); // final coalesced drag, then explicit lift
            assert_eq!(std::mem::take(&mut frames), engine.pointer_up(0.04));
            ic_offline_advance(h, 0.05, ctx, Some(collect));
            assert!(frames.is_empty()); // unchanged is not the same as a lift
            ic_offline_destroy(h);
        }
    }
}
