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
function disconnect() {
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
  if (!connection || connection._rfbConnectionState !== 'connected') return;
  // noVNC is pinned and shipped with its source. TrollVNC interprets the right
  // and middle VNC buttons as Home and Power, regardless of their position.
  RFB.messages.pointerEvent(connection._sock, 0, 0, mask);
  RFB.messages.pointerEvent(connection._sock, 0, 0, 0);
}
function sendText(text) {
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
function setFPSMode(enabled, profile, markers, captured, cursor = false, cursorKey = '`') {
  const changed = fpsEnabled !== Boolean(enabled);
  fpsEnabled = Boolean(enabled);
  if (connection) {
    if (changed && fpsEnabled) connection._keyboard?._allKeysUp();
    if (changed && connection._rfbConnectionState === 'connected') RFB.messages.pointerEvent(connection._sock, 0, 0, 0);
    connection.viewOnly = fpsEnabled;
    connection.qualityLevel = fpsEnabled ? 6 : 8;
    connection.compressionLevel = fpsEnabled ? 1 : 2;
  }
  fpsOverlay.set(enabled, profile, markers, captured, cursor, cursorKey);
}
window.iControl = {
  connect, disconnect, home: () => button(4), power: () => button(2), sendText, setFPSMode,
  credentials: (password) => connection?.sendCredentials({ password }),
};
window.addEventListener('error', (event) => post('error', { reason: String(event.message).slice(0, 200) }));
window.addEventListener('unhandledrejection', () => post('error', { reason: '控制画面资源加载失败' }));
post('ready');
