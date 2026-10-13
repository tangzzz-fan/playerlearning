public struct PlayerKernelRegistry: Sendable {
    public private(set) var kernelTypes: [any PlayerKernelProtocol.Type]

    public init(kernelTypes: [any PlayerKernelProtocol.Type] = []) {
        self.kernelTypes = kernelTypes
    }

    public var firstKernelType: (any PlayerKernelProtocol.Type)? {
        kernelTypes.first
    }

    public var secondKernelType: (any PlayerKernelProtocol.Type)? {
        kernelTypes.count > 1 ? kernelTypes[1] : nil
    }
}
