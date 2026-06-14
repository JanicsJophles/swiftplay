import AppKit
import CoreGraphics
import Foundation

/// Drives a scene's steps against the live app while the `Recorder` rolls,
/// emitting a `Timeline` of where and when each interaction landed.
///
/// It reuses the exact primitives the standalone commands use — `Query` to
/// resolve elements, `Mouse`/`Keyboard` to act — so a scripted promo behaves
/// identically to hand-running `swiftplay click`/`press`/`type`. The only extra
/// is that every action is timestamped on the recorder's capture clock and the
/// resolved element geometry is recorded for the renderer's camera.
struct SceneRunner {
    let scene: Scene
    let pid: pid_t
    let recorder: Recorder

    /// Brief settle after an action so the resulting UI state actually appears in
    /// the footage even if the scene author forgot an explicit `wait`.
    private let settleMs: UInt32 = 250

    func run() -> [Timeline.Event] {
        var events: [Timeline.Event] = []
        let app = AXElement.application(pid: pid)
        activate()

        for step in scene.steps {
            // A `say` on any step lays a caption at the moment the step begins.
            if let say = step.say, !say.isEmpty {
                events.append(Timeline.Event(t: recorder.elapsed(), kind: .caption, label: say, rect: nil, point: nil))
            }

            switch step.action {
            case .wait:
                let ms = step.ms ?? 600
                preciseSleep(ms: ms)

            case .activate:
                activate()
                preciseSleep(ms: 200)

            case .press:
                guard let keys = step.keys else { break }
                events.append(Timeline.Event(t: recorder.elapsed(), kind: .press, label: keys, rect: nil, point: nil))
                Keyboard.press(keys, toPid: pid)
                usleep(settleMs * 1000)

            case .type:
                guard let text = step.text else { break }
                events.append(Timeline.Event(t: recorder.elapsed(), kind: .type, label: text, rect: nil, point: nil))
                Keyboard.type(text, toPid: pid)
                usleep(settleMs * 1000)

            case .click, .hover:
                guard let match = resolve(in: app, step: step),
                      let pos = match.position, let size = match.size, size.width > 0, size.height > 0 else {
                    FileHandle.standardError.write(Data("  · skipped \(step.action.rawValue): no element matched role=\(step.role ?? "*") label=\(step.label ?? "*")\n".utf8))
                    break
                }
                let rect = CGRect(origin: pos, size: size)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let kind: Timeline.Event.Kind = step.action == .click ? .click : .hover
                events.append(Timeline.Event(
                    t: recorder.elapsed(), kind: kind,
                    label: match.text, rect: Timeline.Rect(rect), point: Timeline.Point(center)
                ))
                if step.action == .click {
                    Mouse.click(at: center)
                } else {
                    Mouse.move(to: center)
                }
                usleep(settleMs * 1000)
            }
        }
        return events
    }

    private func resolve(in app: AXElement, step: Scene.Step) -> ElementMatch? {
        Query.find(in: app, role: step.role, text: step.label, maxDepth: step.maxDepth ?? 40).first
    }

    private func activate() {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        usleep(300_000)
    }

    /// Sleep in small slices so a long `wait` doesn't look like a frozen process.
    private func preciseSleep(ms: Int) {
        var remaining = ms
        while remaining > 0 {
            let slice = min(remaining, 100)
            usleep(UInt32(slice) * 1000)
            remaining -= slice
        }
    }
}
