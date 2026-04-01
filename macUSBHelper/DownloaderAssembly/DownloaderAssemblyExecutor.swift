import Foundation
import Darwin

final class DownloaderAssemblyExecutor {
    let request: DownloaderAssemblyRequestPayload
    let workflowID: String
    let sendProgress: (DownloaderAssemblyProgressPayload) -> Void

    let stateQueue = DispatchQueue(label: "macUSB.helper.downloaderAssembly.state")
    var activeProcess: Process?
    var isCancelled = false

    init(
        request: DownloaderAssemblyRequestPayload,
        workflowID: String,
        sendProgress: @escaping (DownloaderAssemblyProgressPayload) -> Void
    ) {
        self.request = request
        self.workflowID = workflowID
        self.sendProgress = sendProgress
    }

    func cancel() {
        stateQueue.sync {
            isCancelled = true
            guard let process = activeProcess, process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    func run() -> DownloaderAssemblyResultPayload {
        do {
            try throwIfCancelled()
            emit(percent: 0.02, status: "Przygotowanie etapu budowania .app")

            let packageURL = URL(fileURLWithPath: request.packagePath)
            guard FileManager.default.fileExists(atPath: packageURL.path) else {
                throw NSError(
                    domain: "macUSBHelper",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Nie znaleziono InstallAssistant.pkg w sesji pobierania."]
                )
            }

            let outputDirectory = URL(fileURLWithPath: request.outputDirectoryPath, isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            emit(percent: 0.10, status: "Instalacja pakietu InstallAssistant.pkg")
            let assembledAppURL = try runInstallerAndLocateApp(packageURL: packageURL)

            try throwIfCancelled()

            let destinationURL = outputDirectory.appendingPathComponent(request.expectedAppName, isDirectory: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            emit(percent: 0.88, status: "Kopiowanie instalatora .app do katalogu sesji")
            try runCommand(
                executable: "/usr/bin/ditto",
                arguments: [assembledAppURL.path, destinationURL.path]
            )

            emit(percent: 1.0, status: "Budowanie instalatora .app zakończone")
            return DownloaderAssemblyResultPayload(
                workflowID: workflowID,
                success: true,
                outputAppPath: destinationURL.path,
                errorMessage: nil
            )
        } catch {
            let message = (error as NSError).localizedDescription
            return DownloaderAssemblyResultPayload(
                workflowID: workflowID,
                success: false,
                outputAppPath: nil,
                errorMessage: message
            )
        }
    }
}
