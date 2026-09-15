import Foundation

public enum ConnectionTag: Sendable {}
public enum ModelDescriptorTag: Sendable {}
public typealias ConnectionID = EntityID<ConnectionTag>
public typealias ModelDescriptorID = EntityID<ModelDescriptorTag>
