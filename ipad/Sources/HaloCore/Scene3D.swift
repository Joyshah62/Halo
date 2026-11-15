import Foundation

/// A selection in Halo's bundled model library. No remote assets or executable scene content.
public struct Scene3DSpec: Codable, Equatable, Identifiable, Sendable {
    public var model: String
    public var focus: String?
    public var caption: String
    public var id: String { "\(model)|\(focus ?? "")|\(caption)" }
    public static let titles = ["brain": "The human brain", "neuron": "Inside a neuron", "animal-cell": "Explore an animal cell"]
    public var isSupported: Bool { Self.titles[model] != nil }
    public var title: String { Self.titles[model] ?? "3D model" }
    public init(model: String, focus: String? = nil, caption: String = "") {
        self.model = model; self.focus = focus; self.caption = caption
    }
}

/// Sent with a question asked from inside the 3D explorer: the model in the student's hands and the part they touched.
public struct ExplorerContext: Codable, Equatable, Sendable {
    public var model: String
    public var focus: String?
    public init(model: String, focus: String? = nil) { self.model = model; self.focus = focus }
}
