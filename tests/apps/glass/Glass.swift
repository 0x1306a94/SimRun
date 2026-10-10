// Glass: Liquid Glass stress test — a GlassEffectContainer whose items morph in and out on a timer (no input needed),
// over a colourful scrolling background so the glass has content to refract.
import SwiftUI
import Combine

@main struct GlassApp: App {
  var body: some Scene { WindowGroup { GlassView() } }
}

struct GlassView: View {
  @State private var expanded = false
  @State private var phase = 0.0
  @Namespace private var ns
  let timer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

  var body: some View {
    ZStack {
      LinearGradient(colors: [.purple, .orange, .teal, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
      VStack(spacing: 18) {
        ForEach(0..<8) { i in
          RoundedRectangle(cornerRadius: 18).fill(Color(hue: Double(i) / 8, saturation: 0.7, brightness: 0.9))
            .frame(height: 60).overlay(Text("Row \(i)").font(.title2.bold()).foregroundStyle(.white))
        }
      }
      .padding()
      .offset(y: sin(phase) * 40)
      VStack {
        Spacer()
        GlassEffectContainer(spacing: 24) {
          HStack(spacing: 24) {
            Image(systemName: "house.fill").font(.title).frame(width: 64, height: 64)
              .glassEffect().glassEffectID("a", in: ns)
            if expanded {
              Image(systemName: "magnifyingglass").font(.title).frame(width: 64, height: 64)
                .glassEffect().glassEffectID("b", in: ns)
              Image(systemName: "person.fill").font(.title).frame(width: 64, height: 64)
                .glassEffect().glassEffectID("c", in: ns)
            }
          }
        }
        .padding(.bottom, 40)
      }
    }
    .onReceive(timer) { _ in
      withAnimation(.spring(duration: 0.5)) { expanded.toggle() }
      withAnimation(.easeInOut(duration: 0.7)) { phase += 1 }
    }
  }
}
