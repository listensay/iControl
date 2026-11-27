//! The communication worker owns this synchronous writer. It calls `heartbeat`
//! every 100 ms (even if there is no input), and closes/drops the wire off-main.
//! The ACK thread is the sole callback producer. Callbacks must not wait on the
//! communication worker: closing the stream wakes the reader and drains it.

use crate::engine::{Contact, Point};
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const HANDSHAKE: Duration = Duration::from_millis(1500);
const IO_LIMIT: Duration = Duration::from_millis(150);
const REPORT_INTERVAL: Duration = Duration::from_millis(200);
const MAX_PENDING: usize = 16;
const MAX_CONTACTS: usize = 10;
const MAX_ID: usize = 16;
const CLOSED: &str = "FPS 输入连接已关闭";
const STALE: &str = "FPS 输入确认超时，已停止游戏输入。请重新连接。";
const INVALID_ACK: &str = "FPS 确认帧无效";

#[derive(Debug)]
pub enum Notice {
    Ack(f64, u8, u8),
    Cursor(bool, bool),
    Failed(String),
}
type Notify = Arc<dyn Fn(Notice) + Send + Sync>;

enum Status {
    Open,
    Failed(String),
    Closed,
}

struct Session {
    status: Status,
    // The daemon processes one frame and writes its ACK before reading the next.
    // Entries are retired strictly in order; unknown/duplicate ACKs grant no credit.
    pending: VecDeque<(u32, Instant)>,
}

impl Session {
    fn deadline(&self, now: Instant) -> Result<Instant, String> {
        match &self.status {
            Status::Failed(message) => return Err(message.clone()),
            Status::Closed => return Err(CLOSED.into()),
            Status::Open => (),
        }
        let sent = self.pending.front().map_or(now, |&(_, sent)| sent);
        let deadline = sent + IO_LIMIT;
        if deadline <= now {
            Err(STALE.into())
        } else {
            Ok(deadline)
        }
    }

    fn reserve(&mut self, seq: u32) -> Result<Instant, String> {
        let now = Instant::now();
        let end = self.deadline(now)?;
        if self.pending.len() == MAX_PENDING {
            return Err("FPS 输入通道暂时拥堵，已停止游戏输入。请重新连接。".into());
        }
        // Reserve before writing: a fast ACK can race the write's return.
        self.pending.push_back((seq, now));
        Ok(end)
    }
}

type Shared = Arc<Mutex<Session>>;

// Both halves can discover an error. Record the first cause before waking the
// other half. Only the reader delivers Failed, never under the session lock.
fn fail(shared: &Shared, socket: &UnixStream, message: String) -> String {
    let mut s = shared.lock().unwrap();
    match &s.status {
        Status::Closed => CLOSED.into(),
        Status::Failed(first) => first.clone(),
        Status::Open => {
            s.status = Status::Failed(message.clone());
            drop(s);
            let _ = socket.shutdown(Shutdown::Both);
            message
        }
    }
}

fn remaining(end: Instant) -> io::Result<Duration> {
    end.checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| io::ErrorKind::TimedOut.into())
}

fn retry(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::Interrupted | io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
    )
}

fn read_chunk(mut socket: &UnixStream, buf: &mut [u8], end: Instant) -> io::Result<usize> {
    socket.set_read_timeout(Some(remaining(end)?))?;
    match socket.read(buf)? {
        0 => Err(io::ErrorKind::UnexpectedEof.into()),
        n => Ok(n),
    }
}

// Socket timeouts apply per syscall. Recompute the remaining total budget on
// every short transfer/EINTR; a trickle of bytes must not extend a deadline.
fn read_until(socket: &UnixStream, mut buf: &mut [u8], end: Instant) -> io::Result<()> {
    while !buf.is_empty() {
        remaining(end)?;
        match read_chunk(socket, buf, end) {
            Ok(n) => buf = &mut buf[n..],
            Err(e) if retry(&e) => continue,
            Err(e) => return Err(e),
        }
    }
    remaining(end).map(|_| ())
}

fn write_until(mut socket: &UnixStream, mut buf: &[u8], end: Instant) -> io::Result<()> {
    while !buf.is_empty() {
        socket.set_write_timeout(Some(remaining(end)?))?;
        match socket.write(buf) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => buf = &buf[n..],
            Err(e) if retry(&e) => continue,
            Err(e) => return Err(e),
        }
    }
    remaining(end).map(|_| ())
}

struct Frame([u8; 8 + 8 * MAX_CONTACTS]);

impl Frame {
    fn new(op: u8, orientation: u8) -> Self {
        let mut f = Self([0; 8 + 8 * MAX_CONTACTS]);
        f.0[0] = op;
        f.0[2] = orientation;
        f
    }

    fn push(&mut self, id: u8, point: Point) -> Result<(), String> {
        if !(0.0..=1.0).contains(&point.x) || !(0.0..=1.0).contains(&point.y) {
            return Err("FPS 输入坐标无效".into());
        }
        let i = 8 + self.0[1] as usize * 8;
        self.0[i] = id;
        for (off, v) in [(2, point.x), (4, point.y)] {
            self.0[i + off..i + off + 2]
                .copy_from_slice(&((v * 65535.0).round() as u16).to_be_bytes());
        }
        self.0[1] += 1;
        Ok(())
    }
}

pub struct Wire {
    socket: Option<UnixStream>,
    reader: Option<JoinHandle<()>>,
    shared: Shared,
    sequence: u32,
    supports_cursor: bool,
}

impl Wire {
    pub fn connect(socket: UnixStream, secret: &[u8], notify: Notify) -> Result<Self, String> {
        if secret.len() != 32 {
            return Err("FPS 控制端凭据缺失或无效".into());
        }
        // CTransport's returned fd has O_NONBLOCK. The Swift wrapper has
        // relinquished it: setting blocking mode affects no other I/O owner.
        socket.set_nonblocking(false).map_err(|e| e.to_string())?;
        let mut hello = [0; 8];
        read_until(&socket, &mut hello, Instant::now() + HANDSHAKE)
            .map_err(|e| format!("FPS 握手失败：{e}"))?;
        let supports_cursor = match &hello {
            b"ICFPS014" => true,
            b"ICFPS013" => false,
            b"ICFPS001" => return Err("iPad 仍在运行旧版 FPS 控制端。请打开“安装 / 配置控制端”升级至 1.4.0，再测试游戏按钮。".into()),
            _ => return Err("iPad FPS 控制端未就绪，请安装 / 配置新版控制端".into()),
        };
        write_until(&socket, secret, Instant::now() + HANDSHAKE)
            .map_err(|e| format!("FPS 认证发送失败：{e}"))?;
        let mut reply = [0; 8];
        read_until(&socket, &mut reply, Instant::now() + HANDSHAKE)
            .map_err(|e| format!("FPS 认证接收失败：{e}"))?;
        match &reply {
            b"READY001" => (),
            b"BUSY0001" => return Err("FPS 输入通道正被另一个客户端使用".into()),
            _ => return Err("FPS 通道凭据不匹配，请重新安装 / 配置控制端".into()),
        }
        // Last fallible operation is spawn: a failed constructor never leaves a
        // reader/callback behind. Both descriptors are owned, never raw borrows.
        let read_socket = socket.try_clone().map_err(|e| e.to_string())?;
        let shared = Arc::new(Mutex::new(Session {
            status: Status::Open,
            pending: VecDeque::with_capacity(MAX_PENDING),
        }));
        let session = Arc::clone(&shared);
        let reader = thread::Builder::new()
            .name("fps-ack".into())
            .spawn(move || {
                if let Err(e) = receive(&read_socket, &session, supports_cursor, &notify) {
                    fail(&session, &read_socket, e);
                }
                let failure = match &session.lock().unwrap().status {
                    Status::Failed(message) => Some(message.clone()),
                    _ => None,
                };
                if let Some(message) = failure {
                    notify(Notice::Failed(message));
                }
            })
            .map_err(|e| format!("无法启动 FPS 确认线程：{e}"))?;
        Ok(Self {
            socket: Some(socket),
            reader: Some(reader),
            shared,
            sequence: 0,
            supports_cursor,
        })
    }

    pub fn supports_cursor(&self) -> bool {
        self.supports_cursor
    }

    fn budget(&self) -> Result<Instant, String> {
        let socket = self.socket.as_ref().ok_or(CLOSED)?;
        let budget = self.shared.lock().unwrap().deadline(Instant::now());
        budget.map_err(|e| fail(&self.shared, socket, e))
    }

    /// Only reliable edges may pipeline. Do not place speculative movement
    /// behind unacknowledged work in the kernel/usbmux socket buffers.
    pub fn drained(&self) -> bool {
        self.shared.lock().unwrap().pending.is_empty()
    }

    pub fn healthy(&self) -> bool {
        self.budget().is_ok()
    }

    fn send(&mut self, mut frame: Frame) -> Result<(), String> {
        let socket = self.socket.as_ref().ok_or(CLOSED)?;
        self.sequence = self.sequence.wrapping_add(1);
        let budget = self.shared.lock().unwrap().reserve(self.sequence);
        let deadline = budget.map_err(|e| fail(&self.shared, socket, e))?;
        frame.0[4..8].copy_from_slice(&self.sequence.to_be_bytes());
        let len = 8 + 8 * frame.0[1] as usize;
        write_until(socket, &frame.0[..len], deadline)
            .map_err(|e| fail(&self.shared, socket, format!("FPS 输入发送失败：{e}")))
    }

    pub fn state(&mut self, orientation: u8, contacts: &[Contact]) -> Result<(), String> {
        if (orientation > 3 && orientation != 255) || contacts.len() > MAX_CONTACTS {
            return Err("FPS 多点触摸状态无效".into());
        }
        let mut points = [None; MAX_ID + 1];
        for c in contacts {
            let id = c.id as usize;
            if !(1..=MAX_ID).contains(&id) || points[id].replace(c.point).is_some() {
                return Err("FPS 触点编号无效".into());
            }
        }
        let mut frame = Frame::new(1, orientation);
        for (id, point) in points.iter().enumerate() {
            if let Some(p) = point {
                frame.push(id as u8, *p)?;
            }
        }
        self.send(frame)
    }

    pub fn cursor(&mut self, orientation: u8, point: Option<Point>) -> Result<(), String> {
        if !self.supports_cursor {
            return self.budget().map(|_| ());
        }
        let mut frame = Frame::new(4, if point.is_some() { orientation } else { 255 });
        if let Some(p) = point {
            if orientation > 3 && orientation != 255 {
                return Err("FPS 鼠标方向无效".into());
            }
            frame.push(0, p)?;
        }
        self.send(frame)
    }

    pub fn release(&mut self) -> Result<(), String> {
        self.send(Frame::new(2, 255))
    }
    pub fn heartbeat(&mut self) -> Result<(), String> {
        self.send(Frame::new(3, 255))
    }

    /// Worker-only. Shutdown wakes a blocked read; after close returns no more
    /// notifications can start. The daemon releases contacts on disconnect; use
    /// `release` to lift all fingers while keeping the session connected.
    pub fn close(&mut self) {
        let reader = self.reader.take();
        let in_callback = reader
            .as_ref()
            .map_or(false, |r| r.thread().id() == thread::current().id());
        if let Some(socket) = self.socket.take() {
            let mut s = self.shared.lock().unwrap();
            // A reentrant close from a callback must suppress even a pending
            // Failed notice: in this case we cannot join the current thread.
            if in_callback || matches!(s.status, Status::Open) {
                s.status = Status::Closed;
            }
            drop(s);
            let _ = socket.shutdown(Shutdown::Both);
        }
        if !in_callback {
            if let Some(r) = reader {
                let _ = r.join();
            }
        }
    }
}

impl Drop for Wire {
    fn drop(&mut self) {
        self.close();
    }
}

fn receive(
    socket: &UnixStream,
    shared: &Shared,
    cursor: bool,
    notify: &Notify,
) -> Result<(), String> {
    let mut flags = None;
    let mut last_report = None;
    let io_error = |e: io::Error| format!("FPS 输入连接中断，已释放触点：{e}");
    let mut idle_deadline = Instant::now() + HANDSHAKE;
    loop {
        let now = Instant::now();
        // Idle reads also wake at least every IO_LIMIT, so a newly sent but
        // completely unacknowledged frame expires even with no further writes.
        let end = shared.lock().unwrap().deadline(now)?.min(idle_deadline);
        if now >= idle_deadline {
            return Err(STALE.into());
        }
        let mut ack = [0; 8];
        let n = match read_chunk(socket, &mut ack, end) {
            Ok(n) => n,
            Err(e) if retry(&e) => continue,
            Err(e) => return Err(io_error(e)),
        };
        // Recheck the pending deadline after waking from an idle read. Don't
        // let a partial ACK grant more time, or create credit for a later send.
        let partial_end = {
            let s = shared.lock().unwrap();
            if s.pending.is_empty() {
                return Err(INVALID_ACK.into());
            }
            s.deadline(Instant::now())?.min(idle_deadline)
        };
        if n < ack.len() {
            read_until(socket, &mut ack[n..], partial_end).map_err(io_error)?;
        }
        let now = Instant::now();
        if now >= partial_end {
            return Err(STALE.into());
        }
        let [op, count, orientation, status, a, b, c, d] = ack;
        if op != 128
            || count > MAX_CONTACTS as u8
            || orientation > 3
            || !(status == 0 || (cursor && (status == 1 || status == 3)))
        {
            return Err(INVALID_ACK.into());
        }
        let seq = u32::from_be_bytes([a, b, c, d]);
        let sent = {
            let mut s = shared.lock().unwrap();
            s.deadline(now)?;
            match s.pending.front() {
                Some(&(id, sent)) if id == seq => {
                    s.pending.pop_front();
                    sent
                }
                _ => return Err(INVALID_ACK.into()),
            }
        };
        idle_deadline = now + HANDSHAKE;
        if flags != Some(status) {
            flags = Some(status);
            notify(Notice::Cursor(status & 1 != 0, status & 2 != 0));
        }
        if last_report.map_or(true, |last| now - last >= REPORT_INTERVAL) {
            shared.lock().unwrap().deadline(Instant::now())?;
            last_report = Some(now);
            notify(Notice::Ack(
                (now - sent).as_secs_f64() * 1000.0,
                count,
                orientation,
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::{self, Receiver, TryRecvError};

    const TOKEN: [u8; 32] = [0xa5; 32];
    const WAIT: Duration = Duration::from_secs(3);

    fn notices() -> (Notify, Receiver<Notice>) {
        let (tx, rx) = mpsc::channel();
        (Arc::new(move |n| tx.send(n).unwrap()), rx)
    }

    fn peer(version: &'static [u8; 8]) -> (Wire, UnixStream, Receiver<Notice>) {
        let (client, mut daemon) = UnixStream::pair().unwrap();
        client.set_nonblocking(true).unwrap(); // same mode as the fd from usbmux
        daemon.set_read_timeout(Some(WAIT)).unwrap();
        let (notify, rx) = notices();
        let server = thread::spawn(move || {
            for chunk in version.chunks(3) {
                daemon.write_all(chunk).unwrap();
            }
            let mut auth = [0; 32];
            daemon.read_exact(&mut auth).unwrap();
            assert_eq!(auth, TOKEN);
            for chunk in b"READY001".chunks(3) {
                daemon.write_all(chunk).unwrap();
            }
            daemon
        });
        let wire = Wire::connect(client, &TOKEN, notify).unwrap();
        (wire, server.join().unwrap(), rx)
    }

    fn expect(peer: &mut UnixStream, bytes: &[u8]) {
        let mut got = vec![0; bytes.len()];
        peer.read_exact(&mut got).unwrap();
        assert_eq!(got, bytes);
    }

    #[test]
    fn revision14_frames_ack_rtt_and_cursor_changes() {
        let (mut wire, mut daemon, rx) = peer(b"ICFPS014");
        assert!(wire.supports_cursor());
        let point = Point { x: 0.5, y: 1.0 };
        wire.state(
            2,
            &[
                Contact { id: 16, point },
                Contact {
                    id: 1,
                    point: Point { x: 0., y: 0. },
                },
            ],
        )
        .unwrap();
        expect(
            &mut daemon,
            &[
                1, 2, 2, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 128, 0, 255, 255, 0, 0,
            ],
        );
        for chunk in [128, 2, 2, 1, 0, 0, 0, 1].chunks(2) {
            daemon.write_all(chunk).unwrap();
        }
        assert!(matches!(
            rx.recv_timeout(WAIT),
            Ok(Notice::Cursor(true, false))
        ));
        match rx.recv_timeout(WAIT).unwrap() {
            Notice::Ack(ms, 2, 2) => assert!((0.0..150.0).contains(&ms)),
            other => panic!("unexpected {other:?}"),
        }
        wire.cursor(3, Some(point)).unwrap();
        expect(
            &mut daemon,
            &[4, 1, 3, 0, 0, 0, 0, 2, 0, 0, 128, 0, 255, 255, 0, 0],
        );
        daemon.write_all(&[128, 2, 3, 3, 0, 0, 0, 2]).unwrap();
        assert!(matches!(
            rx.recv_timeout(WAIT),
            Ok(Notice::Cursor(true, true))
        ));
        wire.cursor(0, None).unwrap();
        wire.release().unwrap();
        wire.heartbeat().unwrap();
        expect(
            &mut daemon,
            &[
                4, 0, 255, 0, 0, 0, 0, 3, 2, 0, 255, 0, 0, 0, 0, 4, 3, 0, 255, 0, 0, 0, 0, 5,
            ],
        );
        wire.close();
        assert!(!wire.healthy());
        assert!(wire.release().is_err());
        assert_eq!(daemon.read(&mut [0; 1]).unwrap(), 0);
    }

    #[test]
    fn touch_only_cursor_does_not_send_or_consume_sequence() {
        let (mut wire, mut daemon, rx) = peer(b"ICFPS013");
        assert!(!wire.supports_cursor());
        wire.cursor(255, Some(Point { x: 0.2, y: 0.3 })).unwrap();
        wire.heartbeat().unwrap();
        expect(&mut daemon, &[3, 0, 255, 0, 0, 0, 0, 1]);
        daemon.write_all(&[128, 0, 3, 0, 0, 0, 0, 1]).unwrap();
        assert!(matches!(
            rx.recv_timeout(WAIT),
            Ok(Notice::Cursor(false, false))
        ));
        assert!(matches!(rx.recv_timeout(WAIT), Ok(Notice::Ack(_, 0, 3))));
        wire.close();
        wire.close();
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Disconnected)));
    }

    #[test]
    fn rejected_greeting_or_auth_never_starts_reader() {
        for (version, reply, expected) in [
            (&b"ICFPS001"[..], &b""[..], "旧版"),
            (b"ICFPS099", b"", "未就绪"),
            (b"ICFP", b"", "握手"),
            (b"ICFPS014", b"BUSY0001", "另一个客户端"),
            (b"ICFPS013", b"DENY0001", "凭据"),
            (b"ICFPS014", b"READ", "认证接收"),
        ] {
            let (client, mut daemon) = UnixStream::pair().unwrap();
            daemon.write_all(version).unwrap();
            daemon.write_all(reply).unwrap();
            daemon.shutdown(Shutdown::Write).unwrap();
            let (notify, rx) = notices();
            let err = Wire::connect(client, &TOKEN, notify).err().unwrap();
            assert!(err.contains(expected), "{err}");
            let mut sent = Vec::new();
            daemon.read_to_end(&mut sent).unwrap();
            assert_eq!(
                sent,
                if reply.is_empty() {
                    &[][..]
                } else {
                    &TOKEN[..]
                }
            );
            assert!(matches!(rx.try_recv(), Err(TryRecvError::Disconnected)));
        }
        let (client, mut daemon) = UnixStream::pair().unwrap();
        let (notify, _) = notices();
        assert!(Wire::connect(client, &[0; 31], notify).is_err());
        assert_eq!(daemon.read(&mut [0; 1]).unwrap(), 0);
    }

    fn failed(wire: &mut Wire, rx: Receiver<Notice>) {
        assert!(matches!(rx.recv_timeout(WAIT), Ok(Notice::Failed(m)) if !m.is_empty()));
        assert!(!wire.healthy());
        assert!(wire.heartbeat().is_err());
        wire.close();
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Disconnected)));
    }

    #[test]
    fn malformed_or_out_of_order_ack_fails_once() {
        for (version, ack) in [
            (b"ICFPS014", [129, 0, 0, 0, 0, 0, 0, 1]),
            (b"ICFPS014", [128, 11, 0, 0, 0, 0, 0, 1]),
            (b"ICFPS014", [128, 0, 255, 0, 0, 0, 0, 1]),
            (b"ICFPS014", [128, 0, 0, 2, 0, 0, 0, 1]),
            (b"ICFPS014", [128, 0, 0, 4, 0, 0, 0, 1]),
            (b"ICFPS013", [128, 0, 0, 1, 0, 0, 0, 1]),
            (b"ICFPS014", [128, 0, 0, 0, 0, 0, 0, 0]),
            (b"ICFPS014", [128, 0, 0, 0, 0, 0, 0, 2]),
        ] {
            let (mut wire, mut daemon, rx) = peer(version);
            wire.heartbeat().unwrap();
            wire.heartbeat().unwrap();
            daemon.write_all(&ack).unwrap();
            failed(&mut wire, rx);
        }
    }

    #[test]
    fn eof_idle_mid_ack_or_without_any_ack_fails_worker() {
        for length in [0, 1, 4, 7] {
            let (mut wire, mut daemon, rx) = peer(b"ICFPS014");
            if length > 0 {
                wire.release().unwrap();
                daemon
                    .write_all(&[128, 0, 0, 0, 0, 0, 0, 1][..length])
                    .unwrap();
            }
            daemon.shutdown(Shutdown::Write).unwrap();
            failed(&mut wire, rx);
        }
        let (mut wire, _daemon, rx) = peer(b"ICFPS014");
        wire.heartbeat().unwrap();
        failed(&mut wire, rx); // no further writer call to drive the timeout
    }

    #[test]
    fn sequence_wrap_does_not_grant_credit_for_duplicate_ack() {
        let (mut wire, mut daemon, rx) = peer(b"ICFPS014");
        wire.sequence = u32::MAX - 1;
        wire.heartbeat().unwrap();
        wire.heartbeat().unwrap();
        expect(
            &mut daemon,
            &[3, 0, 255, 0, 255, 255, 255, 255, 3, 0, 255, 0, 0, 0, 0, 0],
        );
        let last = [128, 0, 0, 0, 255, 255, 255, 255];
        daemon.write_all(&last).unwrap();
        assert!(matches!(
            rx.recv_timeout(WAIT),
            Ok(Notice::Cursor(false, false))
        ));
        assert!(matches!(rx.recv_timeout(WAIT), Ok(Notice::Ack(_, 0, 0))));
        daemon.write_all(&last).unwrap(); // still outstanding: sequence zero
        failed(&mut wire, rx);
    }

    #[test]
    fn half_an_ack_grants_no_credit_and_expires_without_eof() {
        let (mut wire, mut daemon, rx) = peer(b"ICFPS014");
        wire.heartbeat().unwrap();
        daemon.write_all(&[128, 0, 0, 0]).unwrap();
        failed(&mut wire, rx);
    }

    #[test]
    fn in_flight_limit_rejects_frame_without_writing_it() {
        let (mut wire, mut daemon, rx) = peer(b"ICFPS014");
        for _ in 0..MAX_PENDING {
            wire.state(255, &[]).unwrap();
        }
        assert!(wire.state(255, &[]).is_err());
        failed(&mut wire, rx);
        let mut bytes = Vec::new();
        daemon.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes.len(), MAX_PENDING * 8);
    }

    #[test]
    fn late_ack_cannot_revive_an_expired_frame() {
        let (mut wire, mut daemon, rx) = peer(b"ICFPS014");
        wire.release().unwrap();
        // Age the reservation without racing a sleep against the reader.
        wire.shared.lock().unwrap().pending.front_mut().unwrap().1 -= IO_LIMIT;
        let _ = daemon.write_all(&[128, 0, 0, 0, 0, 0, 0, 1]);
        failed(&mut wire, rx);
    }
}
