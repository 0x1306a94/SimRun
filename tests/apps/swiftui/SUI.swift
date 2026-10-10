import SwiftUI
@main struct SUIApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
struct ContentView: View {
    @State var n = 0
    @State var t = ""
    @State var b = true
    var body: some View {
        NavigationStack {
            List {
                Section("Counter") {
                    Stepper("Count: \(n)", value: $n)
                    TextField("Type here", text: $t)
                    Toggle("A toggle", isOn: $b)
                }
                Section("Rows") { ForEach(0..<5) { i in NavigationLink("Row \(i)") { Text("Detail \(i)").font(.largeTitle) } } }
            }.navigationTitle("SwiftUI (sim build)")
        }
    }
}
