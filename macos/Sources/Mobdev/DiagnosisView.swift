import MobdevCore
import SwiftUI

/// Everything that can keep an iPhone from working, checked in one place, each with its fix.
struct DiagnosisView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var usb: USBScreenState?
    @State private var developerMode: Bool??
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Diagnose \(model.state(id)?.name ?? "iPhone")").font(.title2.weight(.semibold))
                Spacer()
                if checking { ProgressView().controlSize(.small) }
            }
            Form {
                if let state = model.state(id) {
                    screenAccess
                    row("USB cable", state.onUSB ? .done : .attention,
                        state.onUSB ? "Connected over USB." : "Plug it in with a USB data cable, unlock it and tap Trust.")
                    picture(state)
                    usbInterface(state)
                    bluetooth(state)
                    pointer(state)
                    developer
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Check Again") { Task { await check() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .task { await check() }
    }

    private func check() async {
        checking = true
        let udid = model.state(id)?.info?.id ?? id
        usb = await Task.detached { USBProbe.screenState(udid: udid) }.value
        developerMode = .some(await (model.hardware(id)?.apps as? DeviceControl)?.developerModeEnabled())
        checking = false
    }

    // MARK: Checks

    @ViewBuilder private var screenAccess: some View {
        if model.setupScreen == .cameraDenied {
            row("Screen access", .attention, "macOS treats the iPhone screen like a camera. Allow \(MobdevPaths.appName) under Camera.")
            Button("Open Privacy Settings") { model.openPrivacySettings("Privacy_Camera") }
        } else if !model.screenStarted {
            row("Screen access", .attention, "Not asked yet.")
            Button("Allow Screen Access") { model.startScreen() }
        } else {
            row("Screen access", .done, "Allowed.")
        }
    }

    @ViewBuilder private func picture(_ state: DeviceState) -> some View {
        switch state.status.screen {
        case .connected(_, let width, let height) where width > 0:
            row("Picture", .done, "\(width) × \(height) pixels arrive.")
        case .connected:
            row("Picture", .waiting, "Connected, waiting for the first picture. Wake and unlock the iPhone.")
        case .locked:
            row("Picture", .waiting, "The iPhone is locked, so it sends no picture. Unlock it.")
        case .noPicture:
            row("Picture", .attention, "No picture arrives: macOS's screen capture helper is stuck. This happens after macOS or Xcode updates.")
            Button("Restart Screen Capture…") { model.restartScreenCapture() }
        default:
            row("Picture", state.onUSB ? .waiting : .info, state.onUSB ? "Unlock the iPhone to see its screen." : "Needs the USB cable.")
        }
    }

    @ViewBuilder private func usbInterface(_ state: DeviceState) -> some View {
        if let usb {
            if usb.hasScreenInterface {
                row("USB screen interface", .done, "Present (USB configuration \(usb.configuration)).")
            } else if state.status.frameSize == nil, state.isConnected {
                row(
                    "USB screen interface", .attention,
                    "Missing (USB configuration \(usb.configuration)): macOS has not switched the iPhone into screen capture. Restarting the screen capture helper does.")
                Button("Restart Screen Capture…") { model.restartScreenCapture() }
            } else {
                row("USB screen interface", .info, "Not active (USB configuration \(usb.configuration)). macOS turns it on when the capture starts.")
            }
        } else {
            row("USB screen interface", .info, checking ? "Checking…" : "The iPhone is not on USB.")
        }
    }

    @ViewBuilder private func bluetooth(_ state: DeviceState) -> some View {
        switch state.status.bluetooth {
        case .connected:
            row("Bluetooth", .done, "Paired. \(MobdevPaths.appName) can tap and type.")
        case .advertising:
            row("Bluetooth", .waiting, "Not paired. On the iPhone: Settings › Bluetooth, then tap “\(HIDPeripheral.macName)” under Other Devices.")
            Button("Show on iPhone Again") { model.offerBluetoothAgain() }
        case .unauthorized:
            row("Bluetooth", .attention, "Bluetooth access is not allowed.")
            Button("Open Privacy Settings") { model.openPrivacySettings("Privacy_Bluetooth") }
        case .starting where !model.bluetoothStarted:
            row("Bluetooth", .attention, "Not started yet.")
            Button("Turn On Bluetooth") { model.startBluetooth() }
        default:
            row("Bluetooth", .attention, state.status.bluetooth.summary)
        }
    }

    @ViewBuilder private func pointer(_ state: DeviceState) -> some View {
        switch state.status.pointer {
        case .follows:
            row("AssistiveTouch", .done, "On, and the pointer lands where it is aimed, so taps and swipes work.")
        case .snaps:
            row("AssistiveTouch", .attention, "Snap to Item is on, so swipes turn into taps. Turn it off in Settings › Accessibility › Touch › AssistiveTouch.")
        case .hidden:
            row("AssistiveTouch", .attention, "The pointer did not appear. Turn on Settings › Accessibility › Touch › AssistiveTouch.")
        case nil:
            row("AssistiveTouch", .info, "Not checked yet. Mobdev checks by itself once the iPhone is ready; the check moves the pointer without tapping.")
            if state.isReady { Button("Check Pointer") { model.checkPointer(id) } }
        }
    }

    @ViewBuilder private var developer: some View {
        switch developerMode {
        case .some(.some(true)):
            row("Developer Mode", .done, "On: installing and debugging your own apps and the UI tree work.")
        case .some(.some(false)):
            row("Developer Mode", .info, "Off. Only needed for your own apps and the UI tree: Settings › Privacy & Security › Developer Mode.")
        case .some(.none):
            row("Developer Mode", .info, "Unknown: needs Xcode, and the iPhone connected to Xcode once. Only needed for your own apps and the UI tree.")
        case .none:
            row("Developer Mode", .info, "Checking…")
        }
    }

    private func row(_ title: String, _ state: StepRow.State, _ detail: String) -> some View {
        StepRow(title: title, detail: detail, state: state)
    }
}
