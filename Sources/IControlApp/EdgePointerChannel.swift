import Foundation
@preconcurrency import WebKit

@MainActor
final class EdgePointerChannel {
    weak private(set) var view: WKWebView?
    private let id = UUID().uuidString
    init(view: WKWebView) { self.view = view }

    func begin(at p: CGPoint, reply: @escaping (CGSize?) -> Void) {
        guard let view else { reply(nil); return }
        view.callAsyncJavaScript("return window.iControl?.beginEdgePointer(id, x, y) ?? null",
                                 arguments: ["id": id, "x": p.x, "y": p.y], in: nil, in: .page) { result in
            guard case .success(let value) = result, let size = value as? [NSNumber], size.count == 2,
                  size.allSatisfy({ (1...65535).contains($0.intValue) }) else { reply(nil); return }
            reply(CGSize(width: size[0].doubleValue, height: size[1].doubleValue))
        }
    }

    func send(_ p: CGPoint, pressed: Bool, wheel: Int = 0, reply: @escaping (Bool) -> Void) {
        guard let view else { reply(false); return }
        let args: [String: Any] = ["id": id, "x": min(1, max(0, p.x)), "y": min(1, max(0, p.y)),
                                   "pressed": pressed, "wheel": wheel]
        view.callAsyncJavaScript("return window.iControl?.updateEdgePointer(id, x, y, pressed, wheel) === true",
                                 arguments: args, in: nil, in: .page) { result in
            if case .success(let value) = result { reply((value as? Bool) == true) } else { reply(false) }
        }
    }

    func end(at p: CGPoint) {
        let args: [String: Any] = ["id": id, "x": min(1, max(0, p.x)), "y": min(1, max(0, p.y))]
        view?.callAsyncJavaScript("window.iControl?.endEdgePointer(id, x, y)", arguments: args,
                                  in: nil, in: .page, completionHandler: nil)
    }
}
