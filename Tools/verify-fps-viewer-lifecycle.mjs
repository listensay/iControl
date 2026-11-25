import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Run the shipped viewer and overlay with a canvas and USB-event bridge double.
// No VNC connection or physical touch is sent by this check.
let videoReady = false, nativeViewport = null;
const events = [], connections = [], observers = [];
const canvasRect = { left: 120, top: 40, width: 640, height: 480 };
const node = () => ({
  style: {}, classList: { toggle() {} }, addEventListener() {}, replaceChildren() {},
  querySelectorAll: () => [], querySelector: () => null,
});
const elements = Object.fromEntries(['screen', 'notice', 'notice-text', 'fps-overlay', 'fps-hint'].map(id => [id, node()]));
class Observer {
  constructor(callback) { this.callback = callback; observers.push(this); }
  observe() {}
  disconnect() { this.callback = null; }
}
class RFB {
  static messages = { pointerEvent() {} };
  constructor() {
    this.handlers = {}; this._canvas = { getBoundingClientRect: () => ({ ...canvasRect }) };
    this._rfbConnectionState = 'connected';
    this._fbWidth = 1024; this._fbHeight = 768;
    connections.push(this);
  }
  addEventListener(name, handler) { this.handlers[name] = handler; }
  clipboardPasteFrom(text) { this.pastedText = text; }
  sendKey() {}
  focus() {}
  disconnect() { this.handlers.disconnect?.({ detail: { clean: true } }); }
}
const context = vm.createContext({
  RFB, URL, ResizeObserver: Observer, MutationObserver: Observer,
  setTimeout(callback) { callback(); },
  document: { getElementById: id => elements[id] },
  window: {
    addEventListener() {}, location: { href: 'http://127.0.0.1/test/index.html' },
    webkit: { messageHandlers: { iControl: { postMessage(event) {
      events.push(event);
      if (event.type === 'connected') videoReady = true;
      if (event.type === 'disconnected') videoReady = false;
      if (event.type === 'fpsViewportRect') nativeViewport = event;
      // FPSController.update clears renderedViewport while videoReady is false.
      if (!videoReady) nativeViewport = null;
    } } } },
  },
});
const overlay = readFileSync(new URL('../Sources/IControlApp/Resources/Viewer/fps-overlay.js', import.meta.url), 'utf8').replace(/^export /gm, '');
const viewer = readFileSync(new URL('../Sources/IControlApp/Resources/Viewer/viewer.js', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
vm.runInContext(`${overlay}\n${viewer}`, context);
const verifyViewport = () => {
  assert(nativeViewport, 'Connected FPS cursor must have canvas coordinates');
  for (const key of ['width', 'height']) assert.equal(nativeViewport[key], canvasRect[key]);
  assert.equal(nativeViewport.x, canvasRect.left); assert.equal(nativeViewport.y, canvasRect.top);
};
vm.runInContext('window.iControl.setFPSMode(true, {}, true, false); window.iControl.connect("");', context);
connections.at(-1).handlers.connect();
verifyViewport();
const beforeClipboard = events.length;
connections.at(-1).handlers.clipboard?.({ detail: { text: 'Incoming clipboard must stay on iPad' } });
assert.equal(events.length, beforeClipboard, 'Incoming clipboard must not be sent to the Mac event bridge');
vm.runInContext('window.iControl.sendText("Explicit text send");', context);
assert.equal(connections.at(-1).pastedText, 'Explicit text send');
assert(events.findIndex(event => event.type === 'connected') < events.findIndex(event => event.type === 'fpsViewportRect'));
connections.at(-1).disconnect();
assert.equal(nativeViewport, null);
vm.runInContext('window.iControl.connect("");', context);
connections.at(-1).handlers.connect();
verifyViewport();
canvasRect.left = 80; canvasRect.top = 10; canvasRect.width = 800; canvasRect.height = 600;
observers.filter(observer => observer.callback).forEach(observer => observer.callback());
verifyViewport();
vm.runInContext('window.iControl.setFPSMode(true, {}, false, true, true, "F1");', context);
assert.equal(elements['fps-hint'].textContent, '鼠标已呼出 · 左键点击 / 拖动 · F1 恢复转向');
vm.runInContext('window.iControl.setFPSMode(true, {}, false, true, false, "F1");', context);
assert.equal(elements['fps-hint'].textContent, 'FPS 输入已捕获 · F1 呼出鼠标 · F8 释放');
console.log('FPS viewer lifecycle passed: connection/reconnect, cursor coordinates, mode hints, no incoming clipboard sync and explicit text sending.');
