// All geometry uses the rendered framebuffer, excluding letterbox bars.
function validRect(rect) {
  return rect && [rect.left, rect.top, rect.width, rect.height].every(Number.isFinite) && rect.width > 0 && rect.height > 0;
}
const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

export function normalizedPoint(clientX, clientY, rect) {
  if (!Number.isFinite(clientX) || !Number.isFinite(clientY) || !validRect(rect)) return null;
  const x = (clientX - rect.left) / rect.width, y = (clientY - rect.top) / rect.height;
  return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? { x, y } : null;
}

export function targetGeometry(profile, target) {
  if (target === 'joystick' && profile.joystick) return { ...profile.joystick, radius: profile.radius ?? 0.085 };
  if (target === 'look' && profile.look) return { ...profile.look };
  const binding = profile.bindings?.find((item) => item.id === target);
  return binding ? { x: binding.x, y: binding.y, size: binding.size ?? 0.075,
    ...(Number.isFinite(binding.endX) && Number.isFinite(binding.endY) ? { endX: binding.endX, endY: binding.endY } : {}) } : null;
}

export function translatedGeometry(geometry, dx, dy, rect) {
  if (!geometry || !validRect(rect) || ![dx, dy].every(Number.isFinite)) return null;
  const horizontal = geometry.radius !== undefined ? Math.min(0.5, geometry.radius * rect.height / rect.width) : (geometry.width ?? 0) / 2;
  const vertical = geometry.radius ?? (geometry.height ?? 0) / 2;
  if (geometry.endX !== undefined) {
    const x = clamp(dx / rect.width, -Math.min(geometry.x, geometry.endX), 1 - Math.max(geometry.x, geometry.endX));
    const y = clamp(dy / rect.height, -Math.min(geometry.y, geometry.endY), 1 - Math.max(geometry.y, geometry.endY));
    return { ...geometry, x: geometry.x + x, y: geometry.y + y, endX: geometry.endX + x, endY: geometry.endY + y };
  }
  return { ...geometry, x: clamp(geometry.x + dx / rect.width, horizontal, 1 - horizontal),
    y: clamp(geometry.y + dy / rect.height, vertical, 1 - vertical) };
}

export function movedSwipeEndpoint(geometry, dx, dy, rect) {
  if (!geometry || geometry.endX === undefined || !validRect(rect) || ![dx, dy].every(Number.isFinite)) return null;
  const endX = clamp(geometry.endX + dx / rect.width, 0, 1), endY = clamp(geometry.endY + dy / rect.height, 0, 1);
  if (Math.hypot(endX - geometry.x, endY - geometry.y) < 0.005) return geometry;
  return { ...geometry, endX, endY };
}

export function resizedGeometry(geometry, handle, dx, dy, rect, keepAspect = false) {
  if (!geometry || !validRect(rect) || ![dx, dy].every(Number.isFinite) || !['nw', 'ne', 'sw', 'se'].includes(handle)) return null;
  const sx = handle.endsWith('e') ? 1 : -1, sy = handle.startsWith('s') ? 1 : -1;
  if (geometry.radius !== undefined) {
    const max = Math.max(0.02, Math.min(0.18, geometry.y, 1 - geometry.y,
      geometry.x * rect.width / rect.height, (1 - geometry.x) * rect.width / rect.height));
    return { ...geometry, radius: clamp(geometry.radius + (sx * dx + sy * dy) / (2 * rect.height), 0.02, max) };
  }
  if (geometry.size !== undefined) {
    return { ...geometry, size: clamp(geometry.size + (sx * dx + sy * dy) / rect.height, 0.04, 0.22) };
  }
  // The opposite corner stays anchored when resizing the look rectangle.
  const anchorX = geometry.x - sx * geometry.width / 2, anchorY = geometry.y - sy * geometry.height / 2;
  const maxWidth = Math.min(0.65, sx > 0 ? 1 - anchorX : anchorX);
  const maxHeight = Math.min(0.80, sy > 0 ? 1 - anchorY : anchorY);
  let width, height;
  if (keepAspect) {
    const w = geometry.width * rect.width, h = geometry.height * rect.height;
    const factor = clamp(1 + (sx * dx * w + sy * dy * h) / (w * w + h * h),
      Math.max(0.10 / geometry.width, 0.10 / geometry.height), Math.min(maxWidth / geometry.width, maxHeight / geometry.height));
    width = geometry.width * factor; height = geometry.height * factor;
  } else {
    width = clamp(geometry.width + sx * dx / rect.width, 0.10, maxWidth);
    height = clamp(geometry.height + sy * dy / rect.height, 0.10, maxHeight);
  }
  return { x: anchorX + sx * width / 2, y: anchorY + sy * height / 2, width, height };
}

export class FPSOverlay {
  constructor(root, hint, post) {
    this.root = root; this.hint = hint; this.post = post;
    this.enabled = false; this.markers = true; this.captured = false;
    this.profile = {}; this.canvas = null; this.connection = null;
    this.drag = null; this.previewFrame = null; this.sequence = 0;
    this.root.tabIndex = 0;
    this.root.addEventListener('pointerdown', (event) => this.pointerDown(event));
    this.root.addEventListener('pointermove', (event) => this.pointerMove(event));
    this.root.addEventListener('pointerup', (event) => this.pointerUp(event));
    this.root.addEventListener('pointercancel', () => this.finishDrag(true));
    this.root.addEventListener('lostpointercapture', () => this.finishDrag(true));
    this.root.addEventListener('keydown', (event) => this.keyDown(event));
    window.addEventListener('blur', () => this.finishDrag(true));
    this.root.addEventListener('mousedown', (event) => {
      if (!this.enabled || !this.profile.calibrating || event.button !== 0) return;
      event.preventDefault(); event.stopImmediatePropagation();
      const point = normalizedPoint(event.clientX, event.clientY, this.canvas?.getBoundingClientRect());
      if (point) this.post('fpsCalibrationPoint', point);
    }, true);
    this.root.addEventListener('contextmenu', (event) => event.preventDefault());
  }
  attach(connection) {
    this.detach(); this.connection = connection;
    this.canvas = connection._canvas;
    if (!this.canvas) return;
    this.resizeObserver = new ResizeObserver(() => this.layout());
    this.resizeObserver.observe(this.canvas);
    this.sizeObserver = new MutationObserver(() => this.layout());
    this.sizeObserver.observe(this.canvas, { attributes: true, attributeFilter: ['width', 'height'] });
    this.layout();
  }
  detach() {
    this.finishDrag(true);
    this.resizeObserver?.disconnect(); this.sizeObserver?.disconnect();
    this.resizeObserver = null; this.sizeObserver = null; this.canvas = null; this.connection = null; this.lastSize = null; this.lastRect = null;
    this.root.style.display = 'none'; this.hint.style.display = 'none';
  }
  set(enabled, profile, markers, captured, cursor = false, cursorKey = '`') {
    const next = profile || {}, sameSession = next.editor && next.editor.session === this.profile.editor?.session;
    this.enabled = Boolean(enabled); this.markers = Boolean(markers); this.captured = Boolean(captured);
    this.cursor = Boolean(cursor); this.cursorKey = cursorKey;
    if (!sameSession || !this.enabled || this.captured) this.finishDrag(true, false);
    // Native acknowledgements can arrive after a newer pointer move. Keep the
    // optimistic geometry until the final event is acknowledged.
    if (sameSession && (this.drag || (next.editor.sequence ?? 0) < this.sequence)) { this.layout(); return; }
    this.sequence = sameSession ? Math.max(this.sequence, next.editor.sequence ?? 0) : next.editor?.sequence ?? 0;
    this.profile = next; this.render(); this.layout();
  }
  get editing() { return this.enabled && Boolean(this.profile.editor) && !this.captured; }

  handles(node) {
    for (const handle of ['nw', 'ne', 'sw', 'se']) {
      const grip = document.createElement('span'); grip.className = `fps-resize-handle ${handle}`;
      grip.dataset.handle = handle; grip.setAttribute('aria-hidden', 'true'); node.appendChild(grip);
    }
  }
  render() {
    this.root.replaceChildren();
    if (this.editing) {
      for (const axis of ['x', 'y']) {
        const guide = document.createElement('div'); guide.className = `fps-guide ${axis}`; this.root.appendChild(guide);
      }
    }
    const add = (id, label, title, kind = '', disabled = false) => {
      const node = document.createElement('div'); node.className = `fps-marker ${kind}`;
      node.dataset.target = id; node.classList.toggle('disabled', disabled);
      node.title = `${title} · ${label}${disabled ? '（未启用）' : ''}`;
      node.setAttribute('role', 'button'); node.setAttribute('aria-label', node.title);
      const key = document.createElement('span'); key.className = 'fps-marker-key';
      key.textContent = label.replace(/^鼠标/, '').replace('侧键 ', '侧键'); node.appendChild(key);
      const caption = document.createElement('span'); caption.className = 'fps-marker-caption';
      caption.textContent = title; node.appendChild(caption);
      if (this.editing && id !== 'look') this.handles(node);
      this.root.appendChild(node); return node;
    };
    const p = this.profile;
    if (p.look) {
      const zone = document.createElement('div'); zone.className = 'fps-look-zone';
      zone.dataset.target = 'look'; zone.setAttribute('aria-label', '鼠标转向区域');
      if (this.editing) this.handles(zone);
      this.root.appendChild(zone); add('look', '鼠标转向', '转向区域', 'look');
    }
    if (p.joystick) add('joystick', 'WASD', '移动摇杆', 'joystick');
    for (const binding of p.bindings || []) {
      add(binding.id, binding.label, binding.title || binding.id, '', binding.enabled === false);
      if (binding.endX !== undefined) {
        const path = document.createElement('div'); path.className = 'fps-swipe-path'; path.dataset.swipeTarget = binding.id;
        this.root.appendChild(path);
        const end = add(binding.id, '终', `${binding.title}滑动终点`, 'swipe-end', binding.enabled === false);
        end.dataset.end = 'true'; end.replaceChildren();
        const label = document.createElement('span'); label.textContent = '终'; end.appendChild(label);
      }
    }
    this.root.classList.toggle('calibrating', Boolean(p.calibrating));
    this.root.classList.toggle('editing', this.editing);
    this.updateSelection(); this.updateHint();
  }
  updateSelection() {
    const selected = this.editing ? this.profile.editor.selected : this.profile.calibrating;
    for (const node of this.root.querySelectorAll('[data-target]')) {
      const active = node.dataset.target === selected;
      node.classList.toggle('selected', active); node.setAttribute('aria-pressed', String(active));
    }
  }
  updateHint() {
    if (this.drag) {
      const g = targetGeometry(this.profile, this.drag.target);
      const size = g.radius !== undefined ? `推杆距离 ${(g.radius * 100).toFixed(1)}%` : g.size !== undefined ? `大小 ${(g.size * 100).toFixed(1)}%` : `${(g.width * 100).toFixed(1)}% × ${(g.height * 100).toFixed(1)}%`;
      this.hint.textContent = `X ${(g.x * 100).toFixed(1)}% · Y ${(g.y * 100).toFixed(1)}% · ${size}`;
    } else {
      this.hint.textContent = this.editing ? '编辑布局 · 拖动移动 · 角点缩放 · 方向键微调' : this.profile.calibrating ? '标定模式 · 点击游戏中的目标位置' : this.captured ? this.cursor ? `鼠标已呼出 · 左键点击 / 拖动 · ${this.cursorKey} 恢复转向` : `FPS 输入已捕获 · ${this.cursorKey} 呼出鼠标 · F8 释放` : 'FPS 模式 · 点击画面或按 F8 捕获鼠标';
    }
  }
  applyGeometry(target, geometry) {
    if (target === 'joystick') {
      this.profile.joystick = { x: geometry.x, y: geometry.y }; this.profile.radius = geometry.radius;
    } else if (target === 'look') this.profile.look = { ...geometry };
    else {
      const binding = this.profile.bindings?.find((item) => item.id === target);
      if (binding) Object.assign(binding, geometry);
    }
    this.layout(); this.updateHint();
  }
  emitEdit(phase, target, geometry = {}) {
    this.post('fpsLayoutEdit', { session: this.profile.editor.session, sequence: ++this.sequence, phase, target, ...geometry });
  }
  command(command) {
    this.post('fpsLayoutCommand', { session: this.profile.editor.session, sequence: ++this.sequence, command });
  }
  pointerDown(event) {
    if (!this.editing || event.button !== 0 || this.drag) return;
    event.preventDefault(); event.stopPropagation(); this.root.focus({ preventScroll: true });
    const node = event.target.closest('[data-target]'), rect = this.canvas?.getBoundingClientRect();
    if (!node || !this.root.contains(node) || !validRect(rect)) return;
    const target = node.dataset.target, geometry = targetGeometry(this.profile, target);
    if (!geometry) return;
    this.profile.editor.selected = target; this.updateSelection();
    this.drag = { target, geometry, rect, pointerId: event.pointerId, x: event.clientX, y: event.clientY,
      handle: node.dataset.end ? 'end' : event.target.closest('[data-handle]')?.dataset.handle };
    this.root.setPointerCapture(event.pointerId); this.root.classList.add('dragging');
    this.emitEdit('begin', target); this.updateHint();
  }
  moveDrag(event) {
    const drag = this.drag;
    if (!drag || event.pointerId !== drag.pointerId) return false;
    const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
    const geometry = drag.handle === 'end' ? movedSwipeEndpoint(drag.geometry, dx, dy, drag.rect)
      : drag.handle ? resizedGeometry(drag.geometry, drag.handle, dx, dy, drag.rect, event.shiftKey)
      : translatedGeometry(drag.geometry, dx, dy, drag.rect);
    if (geometry) this.applyGeometry(drag.target, geometry);
    return Boolean(geometry);
  }
  pointerMove(event) {
    if (!this.moveDrag(event)) return;
    event.preventDefault(); event.stopPropagation();
    if (this.previewFrame === null) this.previewFrame = requestAnimationFrame(() => {
      this.previewFrame = null;
      if (this.drag) this.emitEdit('change', this.drag.target, targetGeometry(this.profile, this.drag.target));
    });
  }
  pointerUp(event) {
    if (!this.drag || event.pointerId !== this.drag.pointerId) return;
    event.preventDefault(); event.stopPropagation(); this.moveDrag(event); this.finishDrag(false);
  }
  finishDrag(cancelled, notify = true) {
    if (!this.drag) return;
    const drag = this.drag; this.drag = null;
    if (this.previewFrame !== null) cancelAnimationFrame(this.previewFrame);
    this.previewFrame = null;
    if (cancelled) this.applyGeometry(drag.target, drag.geometry);
    if (notify && this.profile.editor) this.emitEdit(cancelled ? 'cancel' : 'end', drag.target, targetGeometry(this.profile, drag.target));
    if (this.root.hasPointerCapture(drag.pointerId)) this.root.releasePointerCapture(drag.pointerId);
    this.root.classList.remove('dragging'); this.updateHint();
  }
  keyDown(event) {
    if (!this.editing) return;
    const modifier = event.metaKey || event.ctrlKey, key = event.key.toLowerCase();
    if (key === 'escape') {
      event.preventDefault(); event.stopPropagation();
      if (this.drag) this.finishDrag(true); else this.command('cancel');
      return;
    }
    if (modifier && (key === 'z' || key === 's')) {
      event.preventDefault(); event.stopPropagation();
      this.finishDrag(false); this.command(key === 's' ? 'save' : event.shiftKey ? 'redo' : 'undo');
      return;
    }
    if (modifier || event.altKey || this.drag) return;
    const target = this.profile.editor.selected, geometry = targetGeometry(this.profile, target), rect = this.canvas?.getBoundingClientRect();
    if (!geometry || !validRect(rect)) return;
    let next;
    const step = event.shiftKey ? 10 : 1;
    const directions = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    if (directions[event.key]) next = translatedGeometry(geometry, ...directions[event.key], rect);
    else if (['+', '=', '-', '_'].includes(event.key)) {
      const delta = (event.key === '-' || event.key === '_' ? -1 : 1) * step;
      next = resizedGeometry(geometry, 'se', delta, delta, rect, true);
    }
    if (next) {
      event.preventDefault(); event.stopPropagation(); this.applyGeometry(target, next); this.emitEdit('change', target, next);
    }
  }
  layout() {
    if (!this.canvas || !this.enabled) { this.root.style.display = 'none'; this.hint.style.display = 'none'; return; }
    const rect = this.canvas.getBoundingClientRect();
    if (!validRect(rect)) { this.root.style.display = 'none'; this.hint.style.display = 'none'; return; }
    const rectKey = `${rect.left},${rect.top},${rect.width},${rect.height}`;
    if (rectKey !== this.lastRect) {
      this.lastRect = rectKey;
      this.post('fpsViewportRect', { x: rect.left, y: rect.top, width: rect.width, height: rect.height });
    }
    if (this.drag && [rect.width, rect.height, rect.left, rect.top].some((value, index) => value !== [this.drag.rect.width, this.drag.rect.height, this.drag.rect.left, this.drag.rect.top][index])) {
      this.finishDrag(true);
    }
    this.root.style.left = `${rect.left}px`; this.root.style.top = `${rect.top}px`;
    this.root.style.width = `${rect.width}px`; this.root.style.height = `${rect.height}px`;
    this.root.style.display = this.markers || this.profile.calibrating || this.editing ? 'block' : 'none';
    this.root.style.pointerEvents = this.profile.calibrating || this.editing ? 'auto' : 'none';
    this.hint.style.display = 'block';
    for (const node of this.root.querySelectorAll('.fps-marker')) {
      const geometry = targetGeometry(this.profile, node.dataset.target);
      if (!geometry) continue;
      node.style.left = `${(node.dataset.end ? geometry.endX : geometry.x) * 100}%`;
      node.style.top = `${(node.dataset.end ? geometry.endY : geometry.y) * 100}%`;
      if (node.dataset.target !== 'look') {
        const diameter = Math.max(12, (geometry.radius !== undefined ? geometry.radius * 2 : geometry.size) * rect.height);
        node.style.width = `${diameter}px`; node.style.height = `${diameter}px`;
        node.style.fontSize = `${clamp(diameter * 0.3, 7, 15)}px`;
        node.style.padding = diameter < 28 ? '0' : '3px';
        node.style.setProperty('--grip-offset', `${Math.max(0, (36 - diameter) / 2)}px`);
      }
    }
    for (const path of this.root.querySelectorAll('.fps-swipe-path')) {
      const g = targetGeometry(this.profile, path.dataset.swipeTarget);
      if (!g) continue;
      const dx = (g.endX - g.x) * rect.width, dy = (g.endY - g.y) * rect.height;
      path.style.left = `${g.x * 100}%`; path.style.top = `${g.y * 100}%`;
      path.style.width = `${Math.hypot(dx, dy)}px`; path.style.transform = `rotate(${Math.atan2(dy, dx)}rad)`;
    }
    const look = this.profile.look, zone = this.root.querySelector('.fps-look-zone');
    if (look && zone) {
      zone.style.left = `${(look.x - look.width / 2) * 100}%`; zone.style.top = `${(look.y - look.height / 2) * 100}%`;
      zone.style.width = `${look.width * 100}%`; zone.style.height = `${look.height * 100}%`;
    }
    const selected = this.editing && targetGeometry(this.profile, this.profile.editor.selected);
    const guideX = this.root.querySelector('.fps-guide.x'), guideY = this.root.querySelector('.fps-guide.y');
    if (selected && guideX && guideY) { guideX.style.left = `${selected.x * 100}%`; guideY.style.top = `${selected.y * 100}%`; }
    const width = this.connection?._fbWidth, height = this.connection?._fbHeight;
    const size = `${width}x${height}`;
    if (width > 0 && height > 0 && size !== this.lastSize) {
      this.lastSize = size; this.post('fpsViewport', { width, height });
    }
  }
}
