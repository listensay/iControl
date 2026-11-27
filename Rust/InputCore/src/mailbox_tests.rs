use super::*;

#[test]
fn motion_storm_uses_one_slot_and_does_not_consume_edges() {
    let mut q = Inbox::default();
    let t = Instant::now();
    q.edge(Edge::Key(4, true), t);
    for _ in 0..10_000 {
        q.sample(Motion::Delta(Point { x: 1.0, y: -1.0 }), t, t);
    }
    q.edge(Edge::Key(4, false), t);
    assert_eq!(q.edges.len(), 2);
    assert!(matches!(q.edges[0].1, Edge::Key(4, true)));
    assert!(matches!(q.edges[1].1, Edge::Key(4, false)));
    assert!(matches!(q.motion.unwrap().motion, Motion::Delta(p) if p.x == 10_000.0));
    let later = t + FRESH + Duration::from_millis(1);
    let delta = Motion::Delta(Point { x: 3.0, y: 0.0 });
    q.sample(delta, later, later); // stale bucket is replaced, not renewed
    q.sample(delta, t, later); // late AppKit delivery cannot contaminate the new bucket
    assert!(matches!(q.motion.unwrap().motion, Motion::Delta(p) if p.x == 3.0));
}
#[test]
fn pointer_up_owns_only_the_final_drag_and_next_press_has_no_residue() {
    let mut q = Inbox::default();
    let t = Instant::now();
    let pt = |x| Point { x, y: 0.5 };
    q.edge(Edge::Down(pt(0.1)), t);
    for x in [0.2, 0.3, 0.4] {
        q.sample(Motion::Pointer(Some(pt(x))), t, t);
    }
    q.edge(Edge::Up(None), t);
    q.edge(Edge::Down(pt(0.5)), t);
    assert!(q.motion.is_none());
    assert!(
        matches!(q.edges[1].1, Edge::Up(Some(Sample { motion:Motion::Pointer(Some(p)), .. })) if p.x == 0.4)
    );
}
#[test]
fn release_preempts_due_tick_and_is_a_barrier_before_recapture() {
    let m = Mailbox::default();
    m.edge(Edge::Key(4, true));
    m.sample(Motion::Delta(Point { x: 100.0, y: 20.0 }), 0.0);
    m.edge(Edge::Release);
    m.edge(Edge::Key(5, true));
    assert!(matches!(
        m.next(Instant::now()),
        Ok(Work::Edge(Edge::Release))
    ));
    assert!(matches!(
        m.next(Instant::now() + HEARTBEAT),
        Ok(Work::Edge(Edge::Key(5, true)))
    ));
    assert!(matches!(m.next(Instant::now()), Ok(Work::Deadline)));
    assert!(m.take_motion(Instant::now()).is_none());
}
#[test]
fn saturation_and_overdue_edges_terminate_instead_of_silently_dropping_up() {
    let m = Mailbox::default();
    for _ in 0..EDGE_LIMIT {
        assert!(m.edge(Edge::Key(4, true)));
    }
    assert!(!m.edge(Edge::Key(4, false)));
    assert!(m.next(Instant::now()).is_err());
    assert!(!m.edge(Edge::Release)); // cannot revive a failed session
    let m = Mailbox::default();
    m.inner.lock().unwrap().edge(
        Edge::Key(4, false),
        Instant::now() - MAX_WAIT - Duration::from_millis(1),
    );
    assert!(m.next(Instant::now()).is_err());
    m.stop();
    assert!(matches!(m.next(Instant::now()), Ok(Work::Stop)));
}
