import Foundation
import Vision
import Accelerate

struct FaceFound {
    let rect: CGRect      // normalized, top-left origin
    let roll: Double
    let quality: Float
    let emb: [Float]?
}

struct AnalysisResult {
    var labels: [(String, Float)] = []
    var cats: Int64 = 0
    var people = false
    var faces: [FaceFound] = []
    var failed = false
}

/// Runs Apple Vision on one photo or video frame — fully on device.
enum MediaAnalyzer {
    static func analyze(path: String, kind: Int) -> AnalysisResult {
        var result = AnalysisResult()
        guard let cg = MediaReader.analysisImage(path: path, kind: kind) else {
            result.failed = true
            return result
        }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let classify = VNClassifyImageRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        let animalRequest = VNRecognizeAnimalsRequest()
        do {
            try handler.perform([classify, faceRequest, humanRequest, animalRequest])
        } catch {
            NSLog("PhotoShuffle Vision error: %@", error.localizedDescription)
        }

        // Scene and object labels
        var labels: [(String, Float)] = []
        for observation in classify.results ?? [] where observation.confidence >= 0.2 {
            labels.append((observation.identifier, observation.confidence))
        }
        labels.sort { $0.1 > $1.1 }
        if labels.count > 15 { labels = Array(labels.prefix(15)) }
        for animal in animalRequest.results ?? [] {
            if let top = animal.labels.first, top.confidence >= 0.5 {
                labels.append((top.identifier.lowercased(), top.confidence))
            }
        }

        // Faces
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        var faces = (faceRequest.results ?? []).filter {
            $0.boundingBox.width * W >= 36 && $0.boundingBox.height * H >= 36
        }
        faces.sort { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        if faces.count > 12 { faces = Array(faces.prefix(12)) }

        var quality = [Float](repeating: 0.5, count: faces.count)
        if !faces.isEmpty {
            let qualityRequest = VNDetectFaceCaptureQualityRequest()
            qualityRequest.inputFaceObservations = faces
            if (try? handler.perform([qualityRequest])) != nil, let results = qualityRequest.results {
                for (i, face) in faces.enumerated() {
                    let match = results.first(where: { $0.boundingBox == face.boundingBox }) ?? (i < results.count ? results[i] : nil)
                    if let q = match?.faceCaptureQuality { quality[i] = Float(truncating: q as NSNumber) }
                }
            }
        }

        for (i, face) in faces.enumerated() {
            let bb = face.boundingBox
            let rect = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
            var emb: [Float]? = nil
            if quality[i] >= 0.15 && bb.width * W >= 56 {
                emb = embedding(cg, rect: rect)
            }
            result.faces.append(FaceFound(rect: rect, roll: 0, quality: quality[i], emb: emb))
        }

        // Categories
        let humans = humanRequest.results?.count ?? 0
        let people = !faces.isEmpty || humans > 0 || labels.contains { $0.1 >= 0.35 && MediaCategory.people.matches($0.0) }
        var cats = MediaCategory.bits(for: labels)
        if people { cats |= MediaCategory.people.bit } else { cats &= ~MediaCategory.people.bit }
        let lowerPath = path.lowercased()
        if lowerPath.contains("screenshot") || lowerPath.contains("снимок экрана") || lowerPath.contains("screen shot") {
            cats |= MediaCategory.documents.bit
        }

        result.labels = labels
        result.cats = cats
        result.people = people
        return result
    }

    /// A compact numeric "fingerprint" of a face crop, used to group the same person together.
    static func embedding(_ cg: CGImage, rect: CGRect) -> [Float]? {
        guard let crop = MediaReader.faceCrop(cg, rect: rect, scale: 1.3) else { return nil }
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        let raw: [Float]
        switch observation.elementType {
        case .float: raw = observation.data.floats()
        case .double: raw = observation.data.doubles().map { Float($0) }
        default: return nil
        }
        guard !raw.isEmpty else { return nil }
        return Projection.shared.project(raw)
    }
}

/// Fixed random projection that shrinks feature prints to 256 numbers (keeps distances, saves memory).
final class Projection {
    static let shared = Projection()
    static let outDim = 256

    private var matrices: [Int: [Float]] = [:]
    private let lock = NSLock()

    func project(_ v: [Float]) -> [Float] {
        let n = v.count
        let m = matrix(for: n)
        var out = [Float](repeating: 0, count: Projection.outDim)
        vDSP_mmul(v, 1, m, 1, &out, 1, 1, vDSP_Length(Projection.outDim), vDSP_Length(n))
        return out
    }

    private func matrix(for n: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if let m = matrices[n] { return m }
        var rng = SplitMix64(seed: 0x5EED_FACE_2026)
        let count = n * Projection.outDim
        var m = [Float](repeating: 0, count: count)
        let scale = 1 / sqrt(Double(Projection.outDim))
        var i = 0
        while i < count {
            // Box–Muller: two gaussian numbers per step
            let u1 = max(rng.nextDouble(), 1e-12)
            let u2 = rng.nextDouble()
            let r = sqrt(-2 * log(u1))
            m[i] = Float(r * cos(2 * .pi * u2) * scale)
            if i + 1 < count { m[i + 1] = Float(r * sin(2 * .pi * u2) * scale) }
            i += 2
        }
        matrices[n] = m
        return m
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
