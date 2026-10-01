import OSLog
import SwiftUI

// A tiny app for trying Mobdev on simulators. It prints every tap with its position as a fraction
// of the screen, echoes typed text, counts presses of Ping, and crashes with the argument "crash".
// Its controls have accessibility identifiers, so flows can use tap_element and wait_for_element.
let logger = Logger(subsystem: "dev.mobdev.fixture", category: "app")

@main
struct FixtureApp: App {
    init() {
        print("fixture: launched, arguments \(Array(CommandLine.arguments.dropFirst()))")
        logger.info("fixture: os_log info line")
        if CommandLine.arguments.contains("crash") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let values: [Int] = []
                print("fixture: crashing now")
                _ = values[1]
            }
        }
    }

    var body: some Scene {
        WindowGroup { Screen() }
    }
}

struct Screen: View {
    @State private var text = ""
    @State private var last = "Tap anywhere"
    @State private var pings = 0
    @State private var scrolled = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 24) {
                Text("Mobdev Fixture").font(.largeTitle.bold())
                Text(last).font(.title3).monospacedDigit()
                TextField("Type here", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
                    .onChange(of: text) { _, value in print("fixture: text \(value)") }
                    .onSubmit { print("fixture: submitted \(text)") }
                    .accessibilityIdentifier("fixture.field")
                Button("Ping") {
                    pings += 1
                    print("fixture: ping")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("fixture.ping")
                Text(pings == 0 ? "Not pinged" : "Pinged \(pings)")
                    .accessibilityIdentifier("fixture.pings")
                ScrollView {
                    LazyVStack {
                        ForEach(0..<60) { index in
                            Text("Row \(index)").frame(maxWidth: .infinity).padding(8)
                                .onAppear {
                                    if index > scrolled {
                                        scrolled = index
                                        print("fixture: row \(index) visible")
                                    }
                                }
                        }
                    }
                }
                .frame(height: 220)
                .background(Color.gray.opacity(0.1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .global) { location in
                let fx = location.x / geometry.size.width, fy = location.y / geometry.size.height
                last = String(format: "Tap %.0f, %.0f", location.x, location.y)
                print(String(format: "fixture: tap %.1f %.1f fraction %.3f %.3f", location.x, location.y, fx, fy))
            }
            .gesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .global).onEnded { drag in
                    print(
                        String(
                            format: "fixture: drag from %.0f %.0f to %.0f %.0f", drag.startLocation.x,
                            drag.startLocation.y, drag.location.x, drag.location.y))
                })
        }
        .ignoresSafeArea()
        .onOpenURL { url in print("fixture: opened \(url.absoluteString)") }
    }
}
