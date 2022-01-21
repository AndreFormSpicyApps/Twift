import Foundation

extension Twift {
  public func upload(imageData: Data, mimeType: Media.MimeType = .jpeg) async throws -> MediaFinalizeResponse {
    let initializeResponse = try await initializeUpload(data: imageData, mimeType: mimeType)
    try await appendMediaChunks(mediaKey: initializeResponse.mediaIdString, data: imageData)
    return try await finalizeUpload(mediaKey: initializeResponse.mediaIdString)
  }
  
  fileprivate func initializeUpload(data: Data, mimeType: Media.MimeType) async throws -> MediaInitResponse {
    guard let clientCredentials = clientCredentials, let userCredentials = userCredentials else {
      throw TwiftError.OAuthTokenError
    }
    
    var urlComponents = baseMediaURLComponents()
    urlComponents.queryItems = [
      URLQueryItem(name: "command", value: "INIT"),
      URLQueryItem(name: "media_type", value: mimeType.rawValue),
      URLQueryItem(name: "total_bytes", value: "\(data.count)")
    ]
    
    let url = urlComponents.url!
    var initRequest = URLRequest(url: url)
    
    initRequest.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    initRequest.httpMethod = "POST"
    
    let authHeader = OAuthHelper.calculateSignature(url: url,
                                                    method: "POST",
                                                    consumerCredentials: clientCredentials,
                                                    userCredentials: userCredentials,
                                                    isMediaUpload: true)
    
    initRequest.addValue(authHeader, forHTTPHeaderField: "Authorization")
    
    let (data, _) = try await URLSession.shared.data(for: initRequest)
    
    return try decoder.decode(MediaInitResponse.self, from: data)
  }
  
  fileprivate func appendMediaChunks(mediaKey: String, data: Data) async throws {
    guard let clientCredentials = clientCredentials, let userCredentials = userCredentials else {
      throw TwiftError.OAuthTokenError
    }
    
    let dataEncodedAsBase64Strings = chunkData(data)
    
    for chunk in dataEncodedAsBase64Strings {
      var urlComponents = baseMediaURLComponents()
      
      let index = dataEncodedAsBase64Strings.firstIndex(of: chunk)!
      
      urlComponents.queryItems = [
        URLQueryItem(name: "command", value: "APPEND"),
        URLQueryItem(name: "media_id", value: mediaKey),
        URLQueryItem(name: "media_data", value: chunk),
        URLQueryItem(name: "segment_index", value: "\(index)")
      ]
      
      let url = urlComponents.url!
      var appendRequest = URLRequest(url: url)
      
      appendRequest.httpMethod = "POST"
      appendRequest.addValue("base64", forHTTPHeaderField: "Content-Transfer-Encoding")
      
      let authHeader = OAuthHelper.calculateSignature(url: url,
                                                      method: "POST",
                                                      consumerCredentials: clientCredentials,
                                                      userCredentials: userCredentials,
                                                      isMediaUpload: true)
      appendRequest.addValue(authHeader, forHTTPHeaderField: "Authorization")
      
      let (_, response) = try await URLSession.shared.data(for: appendRequest)
      
      guard let response = response as? HTTPURLResponse,
            response.statusCode == 200 else {
              throw TwiftError.UnknownError
            }
    }
  }
  
  fileprivate func finalizeUpload(mediaKey: String) async throws -> MediaFinalizeResponse {
    guard let clientCredentials = clientCredentials, let userCredentials = userCredentials else {
      throw TwiftError.OAuthTokenError
    }
    
    var urlComponents = baseMediaURLComponents()
    urlComponents.queryItems = [
      URLQueryItem(name: "command", value: "FINALIZE"),
      URLQueryItem(name: "media_id", value: mediaKey),
    ]
    
    let finalizeUrl = urlComponents.url!
    var finalizeRequest = URLRequest(url: finalizeUrl)
    
    finalizeRequest.httpMethod = "POST"
    finalizeRequest.addValue("multipart/form-data", forHTTPHeaderField: "Content-Type")
    
    let finalizeAuthHeader = OAuthHelper.calculateSignature(url: finalizeUrl,
                                                            method: "POST",
                                                            consumerCredentials: clientCredentials,
                                                            userCredentials: userCredentials,
                                                            isMediaUpload: true)
    
    finalizeRequest.addValue(finalizeAuthHeader, forHTTPHeaderField: "Authorization")
    
    let (finalizeResponseData, _) = try await URLSession.shared.data(for: finalizeRequest)
    
    let decodedFinalizeResponse = try decoder.decode(MediaFinalizeResponse.self, from: finalizeResponseData)
    
    return decodedFinalizeResponse
  }
  
  fileprivate func baseMediaURLComponents() -> URLComponents {
    var urlComponents = URLComponents()
    urlComponents.host = "upload.twitter.com"
    urlComponents.path = "/1.1/media/upload.json"
    urlComponents.scheme = "https"
    
    return urlComponents
  }
}

fileprivate func chunkData(_ data: Data) -> [String] {
  let dataLen = data.count
  let chunkSize = ((1024 * 1000) * 4) // MB
  let fullChunks = Int(dataLen / chunkSize)
  let totalChunks = fullChunks + (dataLen % 1024 != 0 ? 1 : 0)
  
  var chunks: [Data] = []
  for chunkCounter in 0..<totalChunks {
    var chunk: Data
    let chunkBase = chunkCounter * chunkSize
    var diff = chunkSize
    if(chunkCounter == totalChunks - 1) {
      diff = dataLen - chunkBase
    }
    
    let range:Range<Data.Index> = (chunkBase..<(chunkBase + diff))
    chunk = data.subdata(in: range)
    chunks.append(chunk)
  }
  
  return chunks.map { $0.base64EncodedString() }
}

fileprivate struct MediaInitResponse: Codable {
  let mediaId: Int
  let mediaIdString: String
  let size: Int
  let expiresAfterSecs: Int
}

public struct MediaFinalizeResponse: Codable {
  let mediaId: Int
  let mediaIdString: String
  let size: Int
  let expiresAfterSecs: Int
  let processingInfo: MediaProcessingInfo?
  
  struct MediaProcessingInfo: Codable {
    let state: String
    let checkAfterSecs: Int
  }
}