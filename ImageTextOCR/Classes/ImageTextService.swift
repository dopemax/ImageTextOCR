import Foundation

@objcMembers
public class ImageTextService: NSObject {
    public static let shared = ImageTextService()
    
    public var uploadHost = ""
    public var uploadParam = ""
    public var uploadFileNamePrefix = "img"
    public var textFilterBlock: ((String) -> Bool) = { $0.count >= 20 }
    
    public var ocrQueueMaxConcurrentOperationCount = 5
    public var uploadQueueMaxConcurrentOperationCount = 5
    
    public func start() {
        UploadManager.shared.startUploadingUnfinished()
        ImageTextRecognizer.shared.fetchAndRecognize { results, processed, total in
            
        }
    }
    
}
