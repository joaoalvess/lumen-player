//
//  URLDownload.swift
//  Lumen
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import CryptoKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if canImport(MobileCoreServices)
import MobileCoreServices.UTType
#endif

public extension URL {
    func data(userAgent: String? = nil) async throws -> Data {
        if isFileURL {
            return try Data(contentsOf: self)
        } else {
            var request = URLRequest(url: self)
            if let userAgent {
                request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        }
    }

    func download(userAgent: String? = nil, completion: @escaping ((String, URL) -> Void)) {
        var request = URLRequest(url: self)
        if let userAgent {
            request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let task = URLSession.shared.downloadTask(with: request) { url, response, _ in
            guard let url, let response else {
                return
            }
            // 下载的临时文件要马上就用。不然可能会马上被清空
            completion(response.suggestedFilename ?? url.lastPathComponent, url)
        }
        task.resume()
    }
}

extension HTTPURLResponse {
    var filename: String? {
        let httpFileName = "attachment; filename="
        if var disposition = value(forHTTPHeaderField: "Content-Disposition"), disposition.hasPrefix(httpFileName) {
            disposition.removeFirst(httpFileName.count)
            return disposition
        }
        return nil
    }
}

extension UIImageView {
    func image(url: URL?) {
        guard let url else { return }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let data = try? Data(contentsOf: url)
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.image = image
            }
        }
    }
}
