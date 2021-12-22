import AVFoundation
import Vision
import UnitIntervalPropertyWrapper


public final class BarcodeScannerOperator: NSObject {
    public typealias BarcodesScannedCompletionHandler = (Result<[VNBarcodeObservation], Swift.Error>) -> Void
    
    public let captureSession: AVCaptureSession

    /// The minimum `VNBarcodeObservation` [confidence level](https://developer.apple.com/documentation/vision/vnobservation/2867220-confidence)
    /// required in order to classify the observation as a found barcode.
    ///
    /// This value will be clamped to [0.0, 1.0].
    @UnitInterval
    public var confidenceThreshold: Double

    
    /// An optional filter to use when configuring a `VNDetectBarcodesRequest` in order
    /// to limit the types of scanned codes that it returns results for.
    ///
    /// If this is left unspecified, the scanner will respond to all `VNBarcodeSymbology` kinds.
    public var symbologyFilter: [VNBarcodeSymbology]?
    
    public var onBarcodesScanned: BarcodesScannedCompletionHandler


    public private(set) var sessionSetupState: SessionSetupState
    public private(set) var sessionRunState: SessionRunState
    
    private var videoDeviceInput: AVCaptureDeviceInput!
    
    /// Records video and provides access to video frames for processing.
    private lazy var videoDeviceOutput: AVCaptureVideoDataOutput = makeVideoDeviceOutput()
    
    private let sampleBufferCallbackQueue: DispatchQueue
    

    ///
    /// - Parameters:
    ///   - captureSession: an `AVCaptureSession` instance.
    ///   - sampleBufferCallbackQueue: A queue to use for video sample buffering.
    ///
    ///     When a new video sample buffer is captured, it is sent to the sample buffer delegate
    ///     using captureOutput(_:didOutput:from:) -- and all delegate methods are
    ///     invoked on the specified dispatch queue.
    ///
    ///     ⚠️ The sample buffer delegate will be invoked at the frame-rate of the camera
    ///     (if the queue is not busy) and it’s expected that you will process that callback data.
    ///     Therefore, it’s super important for to ensure that this does not take place
    ///     on the main (UI) thread.
    public init(
        captureSession: AVCaptureSession = .init(),
        sampleBufferCallbackQueue: DispatchQueue = BarcodeScannerOperator.defaultSampleBufferCallbackQueue,
        confidenceThreshold: Double = 0.5,
        symbologyFilter: [VNBarcodeSymbology]? = nil,
        onBarcodesScanned: @escaping BarcodesScannedCompletionHandler
    ) {
        self.captureSession = captureSession
        self.confidenceThreshold = confidenceThreshold
        self.symbologyFilter = symbologyFilter
        self.sampleBufferCallbackQueue = sampleBufferCallbackQueue
        self.onBarcodesScanned = onBarcodesScanned

        sessionSetupState = .awaitingActivation
        sessionRunState = .idle
    }
}


// MARK: -  Computeds
extension BarcodeScannerOperator {
    
    private var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }
}


// MARK: -  Public Methods
extension BarcodeScannerOperator {
    
    public func checkPermissions() async {
        switch authorizationStatus {
        case .authorized:
            break
        case .notDetermined:
            let isGranted = await AVCaptureDevice.requestAccess(for: .video)
            
            if isGranted == false {
                sessionSetupState = .notAuthorized
            }
        case .restricted,
            .denied:
            sessionSetupState = .notAuthorized
        @unknown default:
            preconditionFailure()
        }
    }

    
    public func configureSession() async {
        defer { captureSession.commitConfiguration() }

        captureSession.beginConfiguration()
        
        guard sessionSetupState != .succeeded else {
            return
        }
        
        captureSession.sessionPreset = .high
        
        guard let videoDevice = makeVideoDevice() else {
            sessionSetupState = .configurationFailedWhileMakingVideoDevice
            return
        }
        
        guard setupVideoDeviceInput(with: videoDevice) else {
            sessionSetupState = .configurationFailedWhileMakingVideoDeviceInput
            return
        }
        
        guard setupVideoDeviceOutput() else {
            sessionSetupState = .configurationFailedWhileAddingDeviceOutput
            return
        }
        
        sessionSetupState = .succeeded
    }
    
    
    public func startRunningSession() {
        guard sessionRunState != .running else { return }
        
        switch sessionSetupState {
        case .awaitingActivation,
                .notAuthorized,
                .configurationFailedWhileMakingVideoDevice,
                .configurationFailedWhileMakingVideoDeviceInput,
                .configurationFailedWhileAddingDeviceInput,
                .configurationFailedWhileAddingDeviceOutput:
            preconditionFailure()
        case .succeeded:
            captureSession.startRunning()
            sessionRunState = .running
        }
    }
    
    
    public func stopRunningSession() {
        guard sessionRunState == .running else { return }

        captureSession.stopRunning()
        sessionRunState = .idle
    }
}


// MARK: -  Private Helpers
extension BarcodeScannerOperator {
    
    private func makeVideoDevice() -> AVCaptureDevice? {
        .default(.builtInWideAngleCamera, for: .video, position: .back)
        ?? .default(.builtInWideAngleCamera, for: .video, position: .front)
    }
    
    
    private func makeVideoDeviceInput(with videoDevice: AVCaptureDevice) throws {
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            throw error
        }
    }
    
    
    private func makeVideoDeviceOutput() -> AVCaptureVideoDataOutput {
        let videoDeviceOutput = AVCaptureVideoDataOutput()
        
        videoDeviceOutput.setSampleBufferDelegate(self, queue: sampleBufferCallbackQueue)
        videoDeviceOutput.videoSettings = Self.videoCaptureOutputSettings
        
        return videoDeviceOutput
    }
    

    private func makeDetectBarcodeRequest() -> VNDetectBarcodesRequest {
        let request = VNDetectBarcodesRequest(
            completionHandler: handleBarcodesRequestCompletion
        )
        
        if let symbologyFilter = symbologyFilter {
            request.symbologies = symbologyFilter
        }
        
        return request
    }
    
    
    private func setupVideoDeviceInput(with videoDevice: AVCaptureDevice) -> Bool {
        do {
            try makeVideoDeviceInput(with: videoDevice)
        } catch {
            sessionSetupState = .configurationFailedWhileMakingVideoDeviceInput
            
            return false
        }
        
        guard captureSession.canAddInput(videoDeviceInput) else {
            sessionSetupState = .configurationFailedWhileAddingDeviceInput
            
            return false
        }
        
        captureSession.addInput(videoDeviceInput)
        
        return true
    }
    
    
    private func setupVideoDeviceOutput() -> Bool {
        guard captureSession.canAddOutput(videoDeviceOutput) else {
            return false
        }
        
        if captureSession.outputs.contains(videoDeviceOutput) == false {
            captureSession.addOutput(videoDeviceOutput)
        }
        
        return true
    }
    
    
    private func handleBarcodesRequestCompletion(
        request: VNRequest,
        potentialError: Swift.Error?
    ) {
        guard potentialError == nil else {
            onBarcodesScanned(.failure(potentialError!))
            return
        }
        
        let barcodes = request
            .results?
            .compactMap { result -> VNBarcodeObservation? in
                guard
                    let barcodeObservation = result as? VNBarcodeObservation,
                    Double(barcodeObservation.confidence) >= confidenceThreshold
                else {
                    return nil
                }

                return barcodeObservation
            }
        ?? []
        
        let sortedBarcodes = barcodes
            .sorted(
                by: { $0.confidence > $1.confidence }
            )
        
        onBarcodesScanned(.success(sortedBarcodes))
    }
}


// MARK: -  Error
extension BarcodeScannerOperator {
    
    public enum Error: Swift.Error {
        case general
    }
}


// MARK: -  SessionSetupState
extension BarcodeScannerOperator {
    
    public enum SessionSetupState {
        case awaitingActivation
        case notAuthorized
        case configurationFailedWhileMakingVideoDevice
        case configurationFailedWhileMakingVideoDeviceInput
        case configurationFailedWhileAddingDeviceInput
        case configurationFailedWhileAddingDeviceOutput
        case succeeded
    }
}


// MARK: -  SessionRunState
extension BarcodeScannerOperator {
    
    public enum SessionRunState {
        case idle
        case running
    }
}


// MARK: -  AVCaptureVideoDataOutputSampleBufferDelegate
extension BarcodeScannerOperator: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let imageRequestHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right
        )
        
        do {
            try imageRequestHandler.perform([makeDetectBarcodeRequest()])
        } catch {
            fatalError(error.localizedDescription)
        }
            
    }
}


extension BarcodeScannerOperator {
    
    public static let videoCaptureOutputSettings: [String: Any] = [
        String(kCVPixelBufferPixelFormatTypeKey): Int(kCVPixelFormatType_32BGRA)
    ]
    
    
    /// A queue to use for video sample buffering.
    ///
    /// When a new video sample buffer is captured, it is sent to the sample buffer delegate
    /// using captureOutput(_:didOutput:from:) -- and all delegate methods are
    /// invoked on the specified dispatch queue.
    ///
    /// ⚠️ The sample buffer delegate will be invoked at the frame-rate of the camera
    /// (if the queue is not busy) and it’s expected that you will process that callback data.
    /// Therefore, it’s super important for to ensure that this does not take place
    /// on the main (UI) thread.
    public static let defaultSampleBufferCallbackQueue: DispatchQueue = .global(
        qos: DispatchQoS.QoSClass.default
    )
}
