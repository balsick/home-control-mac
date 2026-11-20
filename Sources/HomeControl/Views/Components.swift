import AppKit
import HomeCore
import SwiftUI

/// Italian text for numbers, times and appliance states.
enum Format {
  static func watts(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + " W"
  }

  static func time(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
  }

  /// Short, for the menu bar: "42 min", "1 h 05".
  static func remaining(_ interval: TimeInterval) -> String {
    let minutes = max(0, Int((interval / 60).rounded(.up)))
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
  }

  /// "3 min", "2 h", "2 h 10 min".
  static func duration(_ interval: TimeInterval) -> String {
    let minutes = Int(interval / 60)
    if minutes < 1 { return "meno di un minuto" }
    if minutes < 60 { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
  }

  /// "alle 16:57", "domani alle 16:57", or the weekday further out.
  static func dayAndTime(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return "alle \(time(date))" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
      return "domani alle \(time(date))"
    }
    return date.formatted(.dateTime.weekday(.wide).hour().minute())
  }

  /// SmartThings job states, washer and dryer.
  static func phase(_ raw: String?) -> String? {
    guard let raw, raw != "none" else { return nil }
    let labels: [String: String] = [
      "weightsensing": "Rilevamento del carico", "prewash": "Prelavaggio", "wash": "Lavaggio",
      "aiwash": "Lavaggio", "rinse": "Risciacquo", "airinse": "Risciacquo", "spin": "Centrifuga",
      "aispin": "Centrifuga", "drain": "Scarico", "drying": "Asciugatura", "aidrying": "Asciugatura",
      "cooling": "Raffreddamento", "wrinkleprevent": "Antipiega", "finish": "Finito", "finished": "Finito",
      "delaywash": "Partenza ritardata", "airwash": "Air Wash", "refreshing": "Rinfrescamento",
      "dehumidifying": "Deumidificazione", "continuousdehumidifying": "Deumidificazione",
      "sanitizing": "Igienizzazione", "internalcare": "Pulizia interna", "freezeprotection": "Antigelo",
      "thawingfrozeninside": "Scongelamento",
    ]
    return labels[raw.lowercased()] ?? raw
  }
}

/// A titled group on the dashboard.
struct Card<Content: View>: View {
  let title: String
  let systemImage: String
  var trailing: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
        Text(title)
        Spacer(minLength: 4)
        if let trailing { Text(trailing).monospacedDigit() }
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      content
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

struct IconButton: View {
  let systemImage: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(help)
  }
}

struct StateBadge: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(color)
      .background(color.opacity(0.16), in: Capsule())
  }
}

/// Dragging here moves the window.
struct WindowDragArea: NSViewRepresentable {
  final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }

  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ view: NSView, context: Context) {}
}

/// The floating panel's background: the popover's material, with rounded
/// corners (the panel itself is borderless and transparent).
struct PanelMaterial: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    if cornerRadius > 0 { view.maskImage = Self.roundedMask(radius: cornerRadius) }
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}

  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = 2 * radius + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}
