import RFB from './novnc/core/rfb.js';
import { FPSOverlay } from './fps-overlay.js';

let connection = null;
const target = document.getElementById('screen');
const notice = document.getElementById('notice');
const noticeText = document.getElementById('notice-text');
const fpsOverlay = new FPSOverlay(document.getElementById('fps-overlay'), document.getElementById('fps-hint'), post);
let fpsEnabled = false;
function post(type, detail = {}) {
  window.webkit?.messageHandlers?.iControl?.postMessage({ type, ...detail });
}
function showNotice(text) {
  noticeText.textContent = text;
  notice.style.display = 'flex';
}
// Native edge input owns one ordinary VNC socket, never the FPS link. Keep DOM
// input view-only for that lease so a queued noVNC move cannot undo a touch.
let edge = null;
function endEdgePointer(id, x, y) {
  const e = edge;
  if (!e || e.id !== id) return;
  edge = null;
  clearTimeout(e.timeout);
  e.marker.remove();
  if (e.rfb !== connection || e.rfb._rfbConnectionState !== 'connected') return;
  try {
    if (e.width === e.rfb._fbWidth && e.height === e.rfb._fbHeight &&
        [x, y].every(v => Number.isFinite(v) && v >= 0 && v <= 1)) {
      e.x = Math.round(x * (e.width - 1)); e.y = Math.round(y * (e.height - 1));
    }
    RFB.messages.pointerEvent(e.rfb._sock, Math.min(e.x, Math.max(0, e.rfb._fbWidth - 1)),
                             Math.min(e.y, Math.max(0, e.rfb._fbHeight - 1)), 0);
  } catch (_) { /* Best effort on an already closing transport. */ }
  finally { e.rfb.viewOnly = fpsEnabled; }
}
function closeEdgePointer() { if (edge) endEdgePointer(edge.id); }
function updateEdgePointer(id, x, y, pressed, wheel) {
  const e = edge;
  if (!e || e.id !== id) return false;
  const rfb = e.rfb;
  if (connection !== rfb || rfb._rfbConnectionState !== 'connected' || fpsEnabled ||
      rfb._fbWidth !== e.width || rfb._fbHeight !== e.height || document.hidden ||
      ![x, y].every(v => Number.isFinite(v) && v >= 0 && v <= 1) ||
      typeof pressed !== 'boolean' || ![0, 8, 16, 32, 64].includes(wheel)) {
    endEdgePointer(id);
    return false;
  }
  const px = Math.round(x * (e.width - 1)), py = Math.round(y * (e.height - 1));
  const mask = pressed ? 1 : 0;
  // A heartbeat renews the lease without flooding a stationary touch with moves.
  if (px !== e.x || py !== e.y || mask !== e.mask || wheel) {
    e.x = px; e.y = py; e.mask = mask;
    RFB.messages.pointerEvent(rfb._sock, px, py, mask | wheel);
    if (wheel) RFB.messages.pointerEvent(rfb._sock, px, py, mask);
  }
  const rect = rfb._canvas.getBoundingClientRect();
  e.marker.style.left = `${rect.left + x * Math.max(0, rect.width - 1)}px`;
  e.marker.style.top = `${rect.top + y * Math.max(0, rect.height - 1)}px`;
  e.marker.style.background = pressed ? '#3185ff' : 'transparent';
  clearTimeout(e.timeout);
  e.timeout = setTimeout(() => endEdgePointer(id), 2000);
  return true;
}
function beginEdgePointer(id, x, y) {
  const rfb = connection;
  if (edge || !rfb || rfb._rfbConnectionState !== 'connected' || fpsEnabled || rfb.viewOnly ||
      rfb._mouseButtonMask || !rfb._fbWidth || !rfb._fbHeight || !rfb._canvas || document.hidden) return null;
  const marker = document.createElement('div');
  marker.setAttribute('aria-hidden', 'true');
  marker.style.cssText = 'position:fixed;z-index:4;width:13px;height:13px;transform:translate(-50%,-50%);' +
    'border-radius:50%;border:2px solid white;box-shadow:0 0 0 1px #162136,0 1px 4px #0008;pointer-events:none';
  document.body.append(marker);
  edge = { id, rfb, marker, width: rfb._fbWidth, height: rfb._fbHeight, x: 0, y: 0, mask: -1 };
  try {
    // noVNC's viewOnly setter flips the flag BEFORE ungrab; release any keys
    // from the ordinary focused viewer while the server still accepts key-up.
    rfb._keyboard?._allKeysUp();
    rfb.viewOnly = true; // disable DOM input only; do not pause ordinary video
    if (updateEdgePointer(id, x, y, false, 0)) return [edge.width, edge.height];
  } catch (error) { endEdgePointer(id); throw error; }
  return null;
}
window.addEventListener('pagehide', closeEdgePointer);
window.addEventListener('blur', closeEdgePointer);
window.addEventListener('visibilitychange', () => { if (document.hidden) closeEdgePointer(); }, true);
function disconnect() {
  closeEdgePointer();
  fpsOverlay.detach();
  if (connection) {
    const previous = connection;
    connection = null;
    previous.disconnect();
  }
}
function connect(password) {
  disconnect();
  showNotice('正在连接 iPad 画面…');
  const socketURL = new URL('vnc', window.location.href);
  socketURL.protocol = 'ws:';
  try {
    const rfb = new RFB(target, socketURL.href, { credentials: password ? { password } : {} });
    connection = rfb;
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.viewOnly = fpsEnabled;
    rfb.qualityLevel = fpsEnabled ? 6 : 8;
    rfb.compressionLevel = fpsEnabled ? 1 : 2;
    rfb.addEventListener('connect', () => {
      if (connection !== rfb) return;
      notice.style.display = 'none';
      rfb.focus();
      // Native code clears viewport coordinates while videoReady is false.
      // Mark the connection ready before publishing the rendered canvas bounds.
      post('connected');
      fpsOverlay.attach(rfb);
    });
    rfb.addEventListener('disconnect', (event) => {
      if (connection !== rfb) return;
      closeEdgePointer();
      connection = null;
      fpsOverlay.detach();
      showNotice('画面连接已中断，正在等待重连…');
      post('disconnected', { clean: Boolean(event.detail.clean) });
    });
    rfb.addEventListener('credentialsrequired', () => {
      if (connection !== rfb) return;
      showNotice('请输入 iPad 控制密码');
      post('credentialsRequired');
    });
    rfb.addEventListener('securityfailure', (event) => {
      if (connection !== rfb) return;
      post('securityFailure', { reason: String(event.detail.reason || '控制密码验证失败') });
    });
  } catch (error) {
    showNotice('控制画面启动失败');
    post('error', { reason: String(error.message).slice(0, 200) });
  }
}
function button(mask) {
  closeEdgePointer(); // toolbar Home/Power must not replace an active touch
  if (!connection || connection._rfbConnectionState !== 'connected') return;
  // noVNC is pinned and shipped with its source. TrollVNC interprets the right
  // and middle VNC buttons as Home and Power, regardless of their position.
  RFB.messages.pointerEvent(connection._sock, 0, 0, mask);
  RFB.messages.pointerEvent(connection._sock, 0, 0, 0);
}
function sendText(text) {
  closeEdgePointer();
  if (!connection || connection._rfbConnectionState !== 'connected') return;
  const rfb = connection;
  rfb.clipboardPasteFrom(text);
  setTimeout(() => {
    if (connection !== rfb) return;
    rfb.sendKey(0xffeb, 'MetaLeft', true);
    rfb.sendKey(0x76, 'KeyV', true);
    rfb.sendKey(0x76, 'KeyV', false);
    rfb.sendKey(0xffeb, 'MetaLeft', false);
  }, 200);
}
function setFPSMode(enabled, profile, markers, captured, cursor = false, cursorKey = '`', pauseFrames = false) {
  const changed = fpsEnabled !== Boolean(enabled);
  if (enabled) closeEdgePointer(); // send the last up before FPS takes ownership
  fpsEnabled = Boolean(enabled);
  if (connection) {
    if (changed && fpsEnabled) connection._keyboard?._allKeysUp();
    if (changed && connection._rfbConnectionState === 'connected') RFB.messages.pointerEvent(connection._sock, 0, 0, 0);
    connection.frameUpdatesPaused = fpsEnabled && pauseFrames;
    connection.viewOnly = fpsEnabled || edge !== null;
    connection.qualityLevel = fpsEnabled ? 6 : 8;
    connection.compressionLevel = fpsEnabled ? 1 : 2;
  }
  fpsOverlay.set(enabled, profile, markers, captured, cursor, cursorKey);
}
window.iControl = {
  connect, disconnect, home: () => button(4), power: () => button(2), sendText, setFPSMode,
  beginEdgePointer, updateEdgePointer, endEdgePointer,
  credentials: (password) => connection?.sendCredentials({ password }),
};
window.addEventListener('error', (event) => post('error', { reason: String(event.message).slice(0, 200) }));
window.addEventListener('unhandledrejection', () => post('error', { reason: '控制画面资源加载失败' }));
post('ready');
