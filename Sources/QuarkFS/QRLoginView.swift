import AppKit
import CoreImage
import QuarkFSCore
import SwiftUI

@MainActor
final class QRLoginViewModel: ObservableObject {
    @Published var scanURL: URL?
    @Published var statusText = "正在生成登录二维码…"
    @Published var isWorking = true
    @Published var errorText: String?

    private var task: Task<Void, Never>?
    private var attempt = UUID()

    func start(onSuccess: @escaping (String) -> Void) {
        task?.cancel()
        attempt = UUID()
        let currentAttempt = attempt
        scanURL = nil
        errorText = nil
        isWorking = true
        statusText = "正在生成登录二维码…"
        task = Task {
            let client = QuarkLoginClient()
            do {
                let login = try await client.start()
                try Task.checkCancellation()
                scanURL = login.scanURL
                statusText = "请使用夸克 App 扫码并在手机上确认"

                let deadline = Date().addingTimeInterval(120)
                while !Task.isCancelled, Date() < deadline {
                    let result = try await client.poll(login)
                    try Task.checkCancellation()
                    switch result {
                    case .waitingForScan:
                        statusText = "等待扫码…"
                    case .waitingForConfirmation:
                        statusText = "已扫码，请在手机上确认登录"
                    case .authorized(let ticket):
                        statusText = "正在完成登录…"
                        let cookie = try await client.finish(serviceTicket: ticket)
                        try Task.checkCancellation()
                        isWorking = false
                        onSuccess(cookie)
                        return
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                throw CocoaError(.userCancelled, userInfo: [
                    NSLocalizedDescriptionKey: "二维码已过期，请重试"
                ])
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, currentAttempt == attempt else { return }
                isWorking = false
                scanURL = nil
                errorText = error.localizedDescription
                statusText = "登录未完成"
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

struct QRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = QRLoginViewModel()
    let onSuccess: (String) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)

            Text("登录夸克网盘")
                .font(.title2.bold())

            Group {
                if let url = model.scanURL, let image = QRCodeGenerator.image(for: url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 230, height: 230)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                } else if model.isWorking {
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 254, height: 254)
                }
            }

            Text(model.statusText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = model.errorText {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("重新生成") {
                    model.isWorking = true
                    model.errorText = nil
                    model.start(onSuccess: onSuccess)
                }
            }

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 360, height: 500)
        .onAppear { model.start(onSuccess: onSuccess) }
        .onDisappear { model.cancel() }
    }
}

private enum QRCodeGenerator {
    static func image(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 230, height: 230))
    }
}
