import Testing
@testable import PlayerCore

/// `#expect` 的宏展开会把两个操作数各自捕获成变量，存在元类型（`any P.Type`）的 `==` 推断因此断裂
/// —— 同样的表达式写在普通函数里是合法的（见 `PITFALLS` `P-025`）。
private func isSameKernelType(
    _ lhs: (any PlayerKernelProtocol.Type)?,
    _ rhs: any PlayerKernelProtocol.Type
) -> Bool {
    guard let lhs else { return false }
    return lhs == rhs
}

@Suite
struct PlayerKernelRegistryTests {
    private static let stubA: any PlayerKernelProtocol.Type = KernelStub<StubTagA>.self
    private static let stubB: any PlayerKernelProtocol.Type = KernelStub<StubTagB>.self
    private static let stubC: any PlayerKernelProtocol.Type = KernelStub<StubTagC>.self

    @Test
    func testEmptyRegistryExposesNothing() {
        let registry = PlayerKernelRegistry()

        #expect(registry.kernelTypes.isEmpty)
        #expect(registry.firstKernelType == nil)
        #expect(registry.secondKernelType == nil)
    }

    @Test
    func testKernelTypesKeepDeclarationOrder() {
        let registry = PlayerKernelRegistry(kernelTypes: [Self.stubB, Self.stubA, Self.stubC])

        #expect(registry.kernelTypes.count == 3)
        #expect(isSameKernelType(registry.kernelTypes[0], Self.stubB), "第 0 位应为 B")
        #expect(isSameKernelType(registry.kernelTypes[1], Self.stubA), "第 1 位应为 A")
        #expect(isSameKernelType(registry.kernelTypes[2], Self.stubC), "第 2 位应为 C")
    }

    @Test
    func testSingleRegistrationFillsFirstOnly() {
        let registry = PlayerKernelRegistry(kernelTypes: [Self.stubA])

        #expect(isSameKernelType(registry.firstKernelType, Self.stubA))
        #expect(registry.secondKernelType == nil)
    }

    @Test
    func testTwoRegistrationsFillFirstAndSecond() {
        let registry = PlayerKernelRegistry(kernelTypes: [Self.stubA, Self.stubB])

        #expect(isSameKernelType(registry.firstKernelType, Self.stubA))
        #expect(isSameKernelType(registry.secondKernelType, Self.stubB))
    }

    @Test
    func testSecondKernelIsSecondEntryNotLast() {
        let registry = PlayerKernelRegistry(kernelTypes: [Self.stubA, Self.stubB, Self.stubC])

        #expect(isSameKernelType(registry.secondKernelType, Self.stubB), "second 应是第 2 项而不是最后一项")
    }

    @Test
    func testRegisteredKernelTypeIsInstantiable() {
        let registry = PlayerKernelRegistry(kernelTypes: [Self.stubA])

        let kernel = registry.firstKernelType?.init()

        #expect(kernel is KernelStub<StubTagA>)
    }
}
